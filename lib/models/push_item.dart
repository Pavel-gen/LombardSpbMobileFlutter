class PushItem {
  final String id;
  final String title;
  final String body;
  final String link;
  final int timestamp;
  final bool read;

  /// msg_id из data-payload пуша / из серверного ящика (inbox). Пустой у старых
  /// записей. По нему дедуп: один пуш не двоится, придя и push-ом, и из inbox.
  final String msgId;

  const PushItem({
    required this.id,
    required this.title,
    required this.body,
    required this.link,
    required this.timestamp,
    required this.read,
    this.msgId = '',
  });

  PushItem copyWith({bool? read}) {
    return PushItem(
      id: id,
      title: title,
      body: body,
      link: link,
      timestamp: timestamp,
      read: read ?? this.read,
      msgId: msgId,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'link': link,
    'timestamp': timestamp,
    'read': read,
    if (msgId.isNotEmpty) 'msg_id': msgId,
  };

  factory PushItem.fromJson(Map<String, dynamic> json) => PushItem(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    body: json['body'] as String? ?? '',
    link: json['link'] as String? ?? '',
    timestamp: json['timestamp'] as int? ?? 0,
    read: json['read'] as bool? ?? false,
    msgId: json['msg_id'] as String? ?? '',
  );
}
