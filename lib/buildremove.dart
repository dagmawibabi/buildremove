/// Find and clean Flutter/Dart build artifacts, and check which SDK versions
/// and cached packages your projects still use.
///
/// Most people use the `buildremove` command. This library exposes the same
/// scanning, cleaning and usage checks for use from Dart code.
library;

export 'src/cleaner.dart' show CleanMode, CleanResult, cleanProject;
export 'src/scanner.dart'
    show Artifact, Project, ScanResult, artifactPaths, scanProjects;
export 'src/usage.dart' show Usage, analyzeUsage;
export 'src/util.dart' show formatBytes;
