enum GroupColor { blue, purple, green, amber, red, grey }

class WorkspaceGroup {
  final String id;
  final String name;
  final GroupColor color;
  const WorkspaceGroup({required this.id, required this.name, required this.color});

  WorkspaceGroup copyWith({String? name, GroupColor? color}) =>
      WorkspaceGroup(
        id: id,
        name: name ?? this.name,
        color: color ?? this.color,
      );
}
