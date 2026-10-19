unit Agenda.Times;

{$I agenda.inc}

{ Times as the API writes them: a clock time of the tenant ("09:30", minutes
  since midnight), the week's check, and instants between the database
  (Unix seconds) and pascal-jsonmapper-faa's TUtcDateTime.

  Instants used to travel as strings, through a parser and a writer of this
  unit: the mapper's TDateTime took a text without a zone as is and wrote no
  zone back. pascal-jsonmapper-faa 0.7.0 added TUtcDateTime (a zone required
  on input, "Z" written, exact to the millisecond), so the DTOs declare that,
  and only the conversion to and from Unix seconds stays here, with
  TryParseInstant for a query-string value (the mapper's own parser). }

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
/// Unix seconds (UTC), rounded to the second; False for anything else, a
/// time before 1970 included. pascal-jsonmapper-faa's JsonStrToUtcDateTime.
function TryParseInstant(const AText: string; out AUnix: Int64): Boolean;

/// Unix seconds as a UTC TDateTime (for a TUtcDateTime member).
function UnixToUtc(AUnix: Int64): TDateTime;

/// A UTC TDateTime as Unix seconds, rounded to the second.
function UtcToUnix(AValue: TDateTime): Int64;

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

function TryParseInstant(const AText: string; out AUnix: Int64): Boolean;
var
  LValue: TDateTime;
begin
  AUnix := 0;
  try
    LValue := JsonStrToUtcDateTime(AText);
  except
    on EJsonError do
      Exit(False);
  end;
  AUnix := UtcToUnix(LValue);
  Result := AUnix >= 0;
end;

function UnixToUtc(AUnix: Int64): TDateTime;
begin
  Result := UNIX_EPOCH_DAYS + AUnix / SECONDS_PER_DAY;
end;

function UtcToUnix(AValue: TDateTime): Int64;
begin
  Result := Round((AValue - UNIX_EPOCH_DAYS) * SECONDS_PER_DAY);
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
