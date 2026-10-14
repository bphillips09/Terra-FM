import '../engine/radio_types.dart';
import 'band_plan.dart';
import 'radio_state.dart';

/// RBDS (NRSC-4-B) program types. HD uses the same codes.
const _rbds = [
  '', 'News', 'Information', 'Sports', 'Talk', 'Rock', 'Classic Rock', 'Adult Hits',
  'Soft Rock', 'Top 40', 'Country', 'Oldies', 'Soft', 'Nostalgia', 'Jazz', 'Classical',
  'Rhythm and Blues', 'Soft Rhythm and Blues', 'Foreign Language', 'Religious Music',
  'Religious Talk', 'Personality', 'Public', 'College', 'Spanish Talk', 'Spanish Music',
  'Hip-Hop', '', '', 'Weather', 'Emergency Test', 'Emergency',
];

/// European RDS (IEC 62106) program types.
const _rds = [
  '', 'News', 'Current Affairs', 'Information', 'Sport', 'Education', 'Drama', 'Culture',
  'Science', 'Varied', 'Pop Music', 'Rock Music', 'Easy Listening', 'Light Classical',
  'Serious Classical', 'Other Music', 'Weather', 'Finance', "Children's", 'Social Affairs',
  'Religion', 'Phone-In', 'Travel', 'Leisure', 'Jazz', 'Country', 'National Music', 'Oldies',
  'Folk Music', 'Documentary', 'Alarm Test', 'Alarm',
];

/// RDS program type name, or null for "none" and unassigned codes. The
/// Americas broadcast RBDS codes; elsewhere they mean something else.
String? rdsProgramTypeName(int pty, BandPlan band) {
  final names = switch (band) {
    BandPlan.northAmerica || BandPlan.americas => _rbds,
    BandPlan.europe || BandPlan.japan => _rds,
  };
  if (pty <= 0 || pty >= names.length) return null;
  final name = names[pty];
  return name.isEmpty ? null : name;
}

/// Standard category of what is playing: the HD program's type, else the
/// analog signal's RDS program type (which only describes the main program).
String? programCategory(RadioState state, BandPlan band) {
  if (state.audioMode != AudioMode.analog) {
    final info = state.hd.programs[state.program];
    final name = info?.typeName;
    if (info != null && info.programType > 0 && name != null && name != 'Unknown') return name;
    if (state.program != 0) return null;
  }
  final pty = state.fm.rds.pty;
  return pty == null ? null : rdsProgramTypeName(pty, band);
}
