class LogEntry {
  final DateTime timestamp;
  final String message;
  final bool isError;

  LogEntry(this.message, {this.isError = false}) : timestamp = DateTime.now();
}
