import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:io';
import 'dart:io';

import 'package:HolySheetWebserver/generated/holysheet_service.pbgrpc.dart';
import 'package:HolySheetWebserver/grpc_client.dart';
import 'package:HolySheetWebserver/serializer.dart';
import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart' as grpc;
import 'package:meta/meta.dart';
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:http/http.dart' as http;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:intl/intl.dart';
import 'dart:math';

const CLIENT_ID =
    '916425013479-6jdls4crv26mhurj43eakbs72f5e1m8t.apps.googleusercontent.com';
final FULL_SCOPES = [
  'https://www.googleapis.com/auth/userinfo.profile',
  'https://www.googleapis.com/auth/userinfo.email',
  'https://www.googleapis.com/auth/drive'
];
final ACCESS_TOKEN_PATTERN = RegExp(r'^[a-zA-Z0-9-._~+\/]*$');

class Service {
  final uuid = Uuid();
  final router = Router();
  final processingFiles = <FileProcessor>[];
  HolySheetServiceClient client;

  Handler createHandler() {
    bindAuthenticated(
        route: '/list',
        handler: (request, token, query) async {
          final path = query['path'] ?? '';
          final starred = query['starred']?.toLowerCase() == 'true';
          final trashed = query['trashed']?.toLowerCase() == 'true';

          var response = await client.listFiles(ListRequest()
            ..token = token
            ..path = path
            ..starred = starred
            ..trashed = trashed);

          return ok(serialize(response.items));
        });

    bindAuthenticated(
        route: '/upload',
        verb: 'POST',
        chromeWaitBug: true,
        handler: (request, token, query) async {
          try {
            var processingId = uuid.v4();
            var header = HeaderValue.parse(request.headers['content-type']);

            // Only accept one file (For now)
            final first = await request
                .read()
                .transform(
                    MimeMultipartTransformer(header.parameters['boundary']))
                .single;

            if (!first.headers.containsKey('content-disposition')) {
              return getBody(400, 'Header "Content-Disposition" not found');
            }

            header = HeaderValue.parse(first.headers['content-disposition']);
            var fileName = header.parameters['filename'];
            print('Uploading $fileName ($processingId)');
            final file = File(
                '${env['PROCESSING_PATH']}${Platform.pathSeparator}$processingId');
            var fileSink = file.openWrite();
            await first.pipe(fileSink);
            await fileSink.close();

            final processor = FileProcessor(processingId, fileName);
            processingFiles.add(processor);

            var uploadResponse = client
                .uploadFile(UploadRequest()
                  ..token = token
                  ..file = file.absolute.path
                  ..name = fileName
                  ..upload = UploadRequest_Upload.MULTIPART
                  ..compression = UploadRequest_Compression.NONE
                  ..sheetSize = Int64(10000000))
                .printErrors();

            uploadResponse.listen((response) {
              switch (response.status) {
                case UploadResponse_UploadStatus.PENDING:
                  print('Pending...');
                  break;
                case UploadResponse_UploadStatus.UPLOADING:
                  print('Uploading ${response.percentage * 100}%');
                  processor.handler?.call(response.percentage);
                  break;
                case UploadResponse_UploadStatus.COMPLETE:
                  processor.close?.call(1000, 'Success');
                  break;
              }
            }, onError: (e, s) {
              processor.close?.call(1011, 'An error occurred: $e');
              return ise('$e', '$s');
            }, onDone: () => processor.close?.call(1011, 'Incomplete'));

            return ok({
              'message': 'Received successfully',
              'processingToken': processingId,
            });
          } catch (e, s) {
            return ise('$e', '$s');
          }
        });

    bindAuthenticated(
        route: '/download',
        authMethod: AuthMethod.Query,
        handler: (request, token, query) async {
          final id = query['id'] ?? '';

          if (id == null || id.isEmpty || id == 'null' || id.contains(',')) {
            return bad('Invalid ID');
          }

          final downloadId = uuid.v4();
          final file = File(
              '${env['PROCESSING_PATH']}${Platform.pathSeparator}$downloadId');

          final downloaded = await processStream<ListItem, DownloadResponse>(
              await client
                  .downloadFile(DownloadRequest()
                    ..token = token
                    ..id = id
                    ..path = file.absolute.path)
                  .printErrors(), (data) {
            print('Downloading ${data.percentage}%');
            return data.status == DownloadResponse_DownloadStatus.COMPLETE;
          }, (data) => data.item);

          return serveFile(request, downloaded.name, file);
        });

    bindAuthenticated(
        route: '/delete',
        handler: (request, token, query) async {
          final idString = query['id'] ?? '';
          final permanent = (query['permanent'] ?? 'false') == 'true';

          if (idString == null || idString.isEmpty || idString == 'null') {
            return bad('Invalid ID');
          }

          for (var id in idString.split(',')) {
            await client
                .removeFile(RemoveRequest()
                  ..token = token
                  ..id = id
                  ..permanent = permanent)
                .printErrors();
          }

          return ok('Deleted successfully');
        });

    bindAuthenticated(
        route: '/restore',
        handler: (request, token, query) async {
          final idString = query['id'] ?? '';

          if (idString == null || idString.isEmpty || idString == 'null') {
            return bad('Invalid ID');
          }

          for (var id in idString.split(',')) {
            await client
                .restoreFile(RestoreRequest()
                  ..token = token
                  ..id = id)
                .printErrors();
          }

          return ok('Restored successfully');
        });

    bindAuthenticated(
        route: '/star',
        handler: (request, token, query) async {
          final idString = query['id'] ?? '';
          final starred = query['starred']?.toLowerCase() ?? '';

          if ((starred != 'true' && starred != 'false') ||
              idString == null ||
              idString.isEmpty ||
              idString == 'null') {
            return bad('Invalid parameters');
          }

          for (var id in idString.split(',')) {
            await client
                .starRequest(StarRequest()
                  ..token = token
                  ..id = id
                  ..starred = starred == 'true')
                .printErrors();
          }

          return ok('Starred successfully');
        });

    router.get('/websocket', authedWebsocket);

    router.all(
        '/<ignored|.*>', (Request request) => notFound('Page not found'));

    return Pipeline().addMiddleware(_fixCORS).addHandler(router.handler);
  }

  FutureOr<Response> authedWebsocket(Request request) async {
    final processingId = request.url.queryParameters['processingToken'];

    if (processingId == null) {
      return forbidden('No processing token found');
    }

    var processor = processingFiles.firstWhere(
        (processor) => processor.id == processingId,
        orElse: () => null);
    if (!(processor?.accepting ?? false)) {
      return forbidden('No open file processor with ID found');
    }

    return webSocketHandler((WebSocketChannel webSocket) {
      final sink = webSocket.sink;
      processor.handler = (percentage) => sink.add('$percentage');
      processor.close = (code, reason) => webSocket.sink.close(code, reason);
    })(request);
  }

  void bindAuthenticated(
          {@required
              String route,
          @required
              Future<Response> Function(Request, String, Map<String, String>)
                  handler,
          bool chromeWaitBug = false,
          String verb = 'GET',
          AuthMethod authMethod = AuthMethod.Header}) =>
      router.add(verb, route, (Request request) async {
        final token = ({
          AuthMethod.Header: () => request.headers['Authorization'],
          AuthMethod.Query: () => request.url.queryParameters['Authorization'],
        })[authMethod]();

        if (token == null) {
          return forbidden('No token found');
        }

        if (!await verifyToken(token)) {
          return forbidden('Invalid checked token');
        }

        return await handler(
            request, token, request.url?.queryParameters ?? {});
      });

  Future<Response> serveFile(Request request, String name, File file,
      [String contentType]) async {
    var stat = file.statSync();

    var headers = {
      HttpHeaders.contentLengthHeader: stat.size.toString(),
      'Content-Disposition': 'attachment; filename="$name"'
    };

    try {
      print('Sending response...');
      return Response.ok(file.openRead(), headers: headers);
    } finally {
      print('Done with response, deleting file...');
      await file.delete();
    }
  }

  /// Returns a [Response] with the code 200 Okay.
  /// To see [body] docs, see [getBody].
  Response ok(dynamic body) => getBody(200, body);

  /// Returns a [Response] with the code 400 Bad Request.
  /// To see [body] docs, see [getBody].
  Response bad(dynamic body) => getBody(400, body);

  /// Returns a [Response] with the code 403 Forbidden.
  /// To see [body] docs, see [getBody].
  Response forbidden(dynamic body) => getBody(403, body);

  /// Returns a [Response] with the code 403 Forbidden.
  /// To see [body] docs, see [getBody].
  Response notFound(dynamic body) => getBody(404, body);

  /// Returns a [Response] with the code 500 Internal Server Error.
  /// To see [body] docs, see [getBody].
  Response ise(String message, String stacktrace) {
    print(message);
    print(stacktrace);
    return getBody(500, {'message': message, 'stacktrace': stacktrace});
  }

  /// Gets the body, used for [Request]s.
  /// [body] can be either a Map<String, String> which is encoded into a JSON
  /// map, whereas anything else will be [toString]'d and put with an `error`
  /// key.
  Response getBody(int code, dynamic body, {String defaultKey = 'message'}) {
    if (body is String) {
      body = {defaultKey: body ?? 'Unknown message'};
    }
    return Response(code, body: jsonEncode(body));
  }

  /// Processes a stream [stream], until [breakOut] returns true, being compared
  /// with elements in the stream via [listen]. Once completed, [finResult] will
  /// be invoked with the last element and returned.
  Future<R> processStream<R, I>(Stream<I> stream,
      bool Function(I input) breakOut, R Function(I input) finResult) async {
    final completer = Completer<R>();

    StreamSubscription<I> sub;
    sub = stream.listen((i) {
      if (breakOut(i)) {
        sub.cancel();
        completer.complete(finResult(i));
      }
    });

    sub.onError((error) => completer
        .completeError('Ane error occurred during processing: $error'));

    return completer.future;
  }

  /// Decodes post values
  Future<Map<String, String>> decodeRequest(Request request) async =>
      Map.fromEntries((await request.readAsString()).split('&').map((kv) {
        var split =
            kv.split('=').map((str) => Uri.decodeComponent(str)).toList();
        return MapEntry(split[0], split[1]);
      }).toList());

  Future<bool> verifyToken(String accessToken) async {
    try {
      if (accessToken == null || !ACCESS_TOKEN_PATTERN.hasMatch(accessToken)) {
        return Future.value(false);
      }

      var response = await http.get(
          'https://www.googleapis.com/oauth2/v1/tokeninfo?access_token=$accessToken');
      var json = jsonDecode(response.body);

      if (json['audience'] != CLIENT_ID) {
        print('Audience do not match');
        return false;
      }

      var split = json['scope']?.split(' ')?.toSet();
      if (!(split?.containsAll(FULL_SCOPES) ?? true)) {
        print('User missing scope(s)');
        return false;
      }

      return true;
    } catch (ignored) {
      return false;
    }
  }
}

class FileProcessor {
  String id;
  String name;
  void Function(double) handler;
  void Function(int, String) close;

  bool get accepting => handler == null;

  FileProcessor(this.id, this.name);
}

enum AuthMethod { Header, Query }

extension ErrorStreamCatcher<T> on grpc.ResponseStream<T> {
  grpc.ResponseStream<T> printErrors() {
    handleError((error, stack) => print(
        'An error has occurred during a gRPC request stream. Error:\n$error\nStack:\n$stack'));
    return this;
  }
}

extension ErrorFutureCatcher<T> on grpc.ResponseFuture<T> {
  grpc.ResponseFuture<T> printErrors() {
    catchError((error, stack) => print(
        'An error has occurred during a gRPC request future. Error:\n$error\nStack:\n$stack'));
    return this;
  }
}

// for OPTIONS (preflight) requests just add headers and an empty response

Response _options(Request request) =>
    (request.method == 'OPTIONS') ? Response.ok(null, headers: _headers) : null;

Response _cors(Response response) => response.change(headers: _headers);

Middleware _fixCORS =
    createMiddleware(requestHandler: _options, responseHandler: _cors);

int get millsTime => DateTime.now().millisecondsSinceEpoch;

final env = Platform.environment;

Map<String, String> _headers = {
  'x-frame-options': 'allow-from ${env['ALLOW_ORIGIN']}',
  'Access-Control-Allow-Origin': env['ALLOW_ORIGIN'],
  'Access-Control-Expose-Headers': 'Authorization, Content-Type',
  'Access-Control-Allow-Headers':
      'Authorization, Origin, X-Requested-With, Content-Type, Accept',
  'Access-Control-Allow-Methods': 'GET, POST',
  'Access-Control-Max-Age': '9999',
//  'Content-Type': 'application/json',
};

// Run shelf server and host a [Service] instance on port 8080.
void main() async {
  final service = Service();
  final grpcClient = GRPCClient();
  await grpcClient.start(int.tryParse('${env['GRPC']}') ?? 8888);
  service.client = grpcClient.client;

  print('Initialized gRPC client');

  final server = await io.serve(
      service.createHandler(), '0.0.0.0', int.tryParse('${env['PORT']}') ?? 80);

  print('Server running on localhost:${server.port}');
}
