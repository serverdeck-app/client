part of 'console_owner.dart';

final class _ConsoleSession {
  _ConsoleSession({
    required this.id,
    required this.profileId,
    required ConsoleConnectionBinding binding,
    required this.shell,
    required ConsoleCaller creator,
    required this.engine,
  }) : binding = binding,
       creator = creator,
       fence = binding.fence {
    ready.future.ignore();
  }
  final String id, profileId;
  ConsoleConnectionBinding? binding;
  final VersionFence fence;
  final ConsoleShellProfile shell;
  ConsoleCaller? creator;
  final int generation = 1;
  final ConsoleTerminalEngine engine;
  String state = 'opening';
  String? reason;
  int? exitCode;
  bool partial = false, outputScheduled = false, pendingDone = false;
  ConsoleOpening? opening;
  ConsoleChannel? channel;
  void Function()? deadline, offCreator;
  final raw = ListQueue<Uint8List>();
  int rawBytes = 0, inputBytes = 0;
  Future<void> inputTail = Future.value();
  final inputJobs = <WorkCancellation>{};
  _ConsoleLease? lease;
  final ready = Completer<void>();
  (int, int)? pendingResize;
  bool resizing = false;
  OperationFailure? inputFailure;
  String? inputOutcome;
  bool get active => state == 'active' && !pendingDone;
  bool get acceptsOutput => state == 'active' || state == 'opening';
}
