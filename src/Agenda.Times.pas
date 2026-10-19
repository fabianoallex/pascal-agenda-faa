unit Agenda.Times;

{$I agenda.inc}

{ Times as the API writes them: a clock time of the tenant ("09:30", minutes
  since midnight) and an instant (ISO 8601 in UTC, Unix seconds).

  An instant must say its zone. pascal-jsonmapper-faa's TDateTime reads
  "2026-12-24T13:00" without one as is, and writes no zone back: for a value
  stored in UTC a client couldn't tell either way. So the API carries
  instants as strings: TryParseInstant refuses a text without "Z" or an
  offset (the offset converts to UTC, through the mapper's own parser), and
  InstantToStr always writes "Z". The output is built from the Unix seconds
  with integer arithmetic, never through a fraction of a day, so no second is
  lost to rounding. A library candidate (docs/design.md). }

interface

const
  MINUTES_PER_DAY = 1440;
  /// Working hours: every time a multiple of this many minutes.
  CLOCK_STEP_MINUTES = 5;
  /// Working hours: at most this many intervals in a week.
  MAX_WEEK_INTERVALS = 70;

type
  /// One interval of a week: an ISO weekday (1 = Monday) and the tenant's
  /// clock, minutes since midnight, [StartMinute, EndMinute).
  TClockInterval = record
    Weekday: Integer;
    StartMinute: Integer;
    EndMinute: Integer;
  end;
  TClockIntervalArray = array of TClockInterval;

/// "HH:MM", 00:00 to 24:00 (24:00 only as an end), into minutes since
/// midnight.
function TryParseClock(const AText: string; out AMinutes: Integer): Boolean;

/// Minutes since midnight (0 to 1440) as "HH:MM".
function ClockToStr(AMinutes: Integer): string;

/// An ISO 8601 date and time with "Z" or an offset (+hh:mm, -hh:mm), into
/// Unix seconds (UTC); False for anything else, a time before 1970 included.
function TryParseInstant(const AText: string; out AUnix: Int64): Boolean;

/// Unix seconds as "YYYY-MM-DDTHH:MM:SSZ".
function InstantToStr(AUnix: Int64): string;

/// Sorts AIntervals by weekday and start, and returns what is wrong with
/// them as a week ('' when nothing): a weekday outside 1-7, a time not a
/// multiple of CLOCK_STEP_MINUTES, a start not before its end, two intervals
/// of one day that overlap (touching is fine), more than MAX_WEEK_INTERVALS.
/// A night shift is two intervals: one to 24:00, one from 00:00.
function WeekProblem(var AIntervals: TClockIntervalArray): string;

implementation

uses
  SysUtils,
  PascalJsonMapper.Json;

const
  UNIX_EPOCH_DAYS = 25569; // 1970-01-01 as a TDateTime
  SECONDS_PER_DAY = 86400;

function TryParseClock(const AText: string; out AMinutes: Integer): Boolean;
var
  H, M: Integer;
begin
  AMinutes := 0;
  Result := (Length(AText) = 5) and (AText[3] = ':') and
    CharInSet(AText[1], ['0'..'9']) and CharInSet(AText[2], ['0'..'9']) and
    CharInSet(AText[4], ['0'..'9']) and CharInSet(AText[5], ['0'..'9']);
  if not Result then
    Exit;
  H := (Ord(AText[1]) - Ord('0')) * 10 + Ord(AText[2]) - Ord('0');
  M := (Ord(AText[4]) - Ord('0')) * 10 + Ord(AText[5]) - Ord('0');
  Result := (M <= 59) and ((H <= 23) or ((H = 24) and (M = 0)));
  if Result then
    AMinutes := H * 60 + M;
end;

function ClockToStr(AMinutes: Integer): string;
begin
  Result := Format('%.2d:%.2d', [AMinutes div 60, AMinutes mod 60]);
end;

// True when the time part (after the date's "T") ends in a zone: "Z", or a
// sign after the clock.
function HasZone(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(AText) < 17 then // YYYY-MM-DDTHH:MM and a zone
    Exit;
  if not CharInSet(AText[11], ['T', 't']) then
    Exit;
  for I := 12 to Length(AText) do
    if CharInSet(AText[I], ['Z', 'z', '+', '-']) then
      Exit(True);
end;

function TryParseInstant(const AText: string; out AUnix: Int64): Boolean;
var
  LText: string;
  LValue: TDateTime;
begin
  AUnix := 0;
  LText := Trim(AText);
  Result := HasZone(LText);
  if not Result then
    Exit;
  try
    LValue := JsonStrToDateTime(LText);
  except
    on EJsonError do
      Exit(False);
  end;
  AUnix := Round((LValue - UNIX_EPOCH_DAYS) * SECONDS_PER_DAY);
  Result := AUnix >= 0;
end;

function InstantToStr(AUnix: Int64): string;
var
  LSeconds: Integer;
begin
  LSeconds := Integer(AUnix mod SECONDS_PER_DAY);
  Result := JsonDateToStr(UNIX_EPOCH_DAYS + AUnix div SECONDS_PER_DAY) +
    Format('T%.2d:%.2d:%.2dZ', [LSeconds div 3600, LSeconds div 60 mod 60, LSeconds mod 60]);
end;

function WeekProblem(var AIntervals: TClockIntervalArray): string;
var
  I, J: Integer;
  LItem: TClockInterval;
begin
  Result := '';
  if Length(AIntervals) > MAX_WEEK_INTERVALS then
    Exit(Format('A week has at most %d intervals.', [MAX_WEEK_INTERVALS]));
  for I := 0 to High(AIntervals) do
  begin
    LItem := AIntervals[I];
    if (LItem.Weekday < 1) or (LItem.Weekday > 7) then
      Exit(Format('intervals[%d]: "weekday" must be 1 (Monday) to 7 (Sunday).', [I]));
    if (LItem.StartMinute mod CLOCK_STEP_MINUTES <> 0) or
      (LItem.EndMinute mod CLOCK_STEP_MINUTES <> 0) then
      Exit(Format('intervals[%d]: times must be multiples of %d minutes.',
        [I, CLOCK_STEP_MINUTES]));
    if (LItem.StartMinute < 0) or (LItem.EndMinute > MINUTES_PER_DAY) or
      (LItem.StartMinute >= LItem.EndMinute) then
      Exit(Format('intervals[%d]: "from" must come before "to", within one day.', [I]));
  end;
  // Insertion sort: a week is a few dozen intervals.
  for I := 1 to High(AIntervals) do
  begin
    LItem := AIntervals[I];
    J := I - 1;
    while (J >= 0) and ((AIntervals[J].Weekday > LItem.Weekday) or
      ((AIntervals[J].Weekday = LItem.Weekday) and
      (AIntervals[J].StartMinute > LItem.StartMinute))) do
    begin
      AIntervals[J + 1] := AIntervals[J];
      Dec(J);
    end;
    AIntervals[J + 1] := LItem;
  end;
  for I := 1 to High(AIntervals) do
    if (AIntervals[I].Weekday = AIntervals[I - 1].Weekday) and
      (AIntervals[I].StartMinute < AIntervals[I - 1].EndMinute) then
      Exit(Format('Weekday %d: %s-%s overlaps %s-%s.', [AIntervals[I].Weekday,
        ClockToStr(AIntervals[I - 1].StartMinute), ClockToStr(AIntervals[I - 1].EndMinute),
        ClockToStr(AIntervals[I].StartMinute), ClockToStr(AIntervals[I].EndMinute)]));
end;

end.
