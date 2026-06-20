class UserProfile {
  final String id;
  final String email;
  final String handle;

  const UserProfile({
    required this.id,
    required this.email,
    required this.handle,
  });

  String get displayHandle => '@$handle';
}
