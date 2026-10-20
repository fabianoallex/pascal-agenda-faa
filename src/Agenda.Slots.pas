unit Agenda.Slots;

{$I agenda.inc}

{ Free slots: a professional's working hours (the tenant's local clock)
  turned into instants in the tenant's time zone, minus what is busy (time
  off, and appointments from M2's booking on), cut into the starts a service
  fits. No database and no HTTP here: Agenda.Availability reads the rows and
  calls this.

  - Working hours to instants: each local day's intervals through
    pascal-common-faa's IPcTimeZone.ToUtc with gapStartOfAfter and
    overlapEarlier, the rules of its DayBounds. An edge in a daylight-saving
    gap (02:30 on the day the clock jumps from 02:00 to 03:00) becomes the
    jump: 02:00-05:00 is two hours that day. An edge in an overlap (01:30
    twice on the day the clock goes back) takes the first one: 00:00-03:00
    is four hours that day, as worked. Intervals that touch once in instants
    become one span, so a night shift written as 22:00-24:00 plus 00:00-02:00
    (the week can't cross midnight) takes a service that crosses it.
  - Starts every AStepMinutes of real time from the start of each span, so
    the grid stays the same before and after a transition.
  - A start is free when the service ends inside the span and the service
    plus its buffer (cleaning, preparing the next customer) meets nothing
    busy. The buffer may run past the end of the span: the room is cleaned
    after closing.
  - A slot belongs to the local day it starts on; starts before ANow are
    left out.

  Instants are Unix seconds (UTC), as the database keeps them. }

interface

uses
  PascalCommon.TimeZones,
  Agenda.Times;

const
  /// Free slots start on this grid, from the start of each working span.
  SLOT_STEP_MINUTES = 15;
  /// GET .../availability: at most this many days in one answer.
  MAX_AVAILABILITY_DAYS = 14;

type
  /// [StartUtc, EndUtc), Unix seconds.
  TSpan = record
    StartUtc, EndUtc: Int64;
  end;
  TSpanArray = array of TSpan;

  TSlotStarts = array of Int64;

/// "YYYY-MM-DD" as a local date (00:00); False for anything else.
function TryParseLocalDate(const AText: string; out ADate: TPcLocalDateTime): Boolean;

/// The first instant of local day AFirstDay and the first of the day after
/// ADays days: the window whose slots an answer lists.
procedure DaysWindow(const AZone: IPcTimeZone; const AFirstDay: TPcLocalDateTime;
  ADays: Integer; out AFrom, ATo: Int64);

/// AWeek on the local days from the day before AFirstDay to the day after
/// the last one (so a span crossing midnight at either end is whole), as
/// instants of AZone, sorted, the touching and overlapping ones joined.
function WorkingSpans(const AZone: IPcTimeZone; const AWeek: TClockIntervalArray;
  const AFirstDay: TPcLocalDateTime; ADays: Integer): TSpanArray;

/// ASpans sorted by start, the touching and overlapping ones joined.
function JoinSpans(const ASpans: TSpanArray): TSpanArray;

/// The starts in [AFrom, ATo), not before ANow, where a service of
/// ADurationMinutes fits in AWorking and the service plus ABufferMinutes
/// meets nothing of ABusy. Both lists in any order.
function FreeSlots(const AWorking, ABusy: TSpanArray; ADurationMinutes, ABufferMinutes,
  AStepMinutes: Integer; AFrom, ATo, ANow: Int64): TSlotStarts;

/// AUtc as AZone's clock with its offset: '2026-11-01T01:30:00-04:00'.
function LocalIso(const AZone: IPcTimeZone; AUtc: Int64): string;

implementation

uses
  SysUtils;

function TryParseLocalDate(const AText: string; out ADate: TPcLocalDateTime): Boolean;
var
  I: Integer;
begin
  ADate := TPcLocalDateTime.Create(1, 1, 1);
  Result := (Length(AText) = 10) and (AText[5] = '-') and (AText[8] = '-');
  if not Result then
    Exit;
  for I := 1 to 10 do
    if not (I in [5, 8]) and not CharInSet(AText[I], ['0'..'9']) then
      Exit(False);
  ADate := TPcLocalDateTime.Create(StrToInt(Copy(AText, 1, 4)), StrToInt(Copy(AText, 6, 2)),
    StrToInt(Copy(AText, 9, 2)));
  Result := ADate.IsValid;
end;

procedure DaysWindow(const AZone: IPcTimeZone; const AFirstDay: TPcLocalDateTime;
  ADays: Integer; out AFrom, ATo: Int64);
var
  LLast: TPcLocalDateTime;
  LIgnored: Int64;
begin
  AZone.DayBounds(AFirstDay.Year, AFirstDay.Month, AFirstDay.Day, AFrom, LIgnored);
  LLast := AFirstDay.AddDays(ADays - 1);
  AZone.DayBounds(LLast.Year, LLast.Month, LLast.Day, LIgnored, ATo);
end;

// Insertion sort by start: a few dozen spans.
procedure SortSpans(var ASpans: TSpanArray);
var
  I, J: Integer;
  LItem: TSpan;
begin
  for I := 1 to High(ASpans) do
  begin
    LItem := ASpans[I];
    J := I - 1;
    while (J >= 0) and (ASpans[J].StartUtc > LItem.StartUtc) do
    begin
      ASpans[J + 1] := ASpans[J];
      Dec(J);
    end;
    ASpans[J + 1] := LItem;
  end;
end;

function JoinSpans(const ASpans: TSpanArray): TSpanArray;
var
  LSorted: TSpanArray;
  I, LCount: Integer;
begin
  LSorted := Copy(ASpans);
  SortSpans(LSorted);
  Result := nil;
  SetLength(Result, Length(LSorted));
  LCount := 0;
  for I := 0 to High(LSorted) do
    if LSorted[I].EndUtc <= LSorted[I].StartUtc then
      Continue // empty: an interval wholly inside a gap
    else if (LCount > 0) and (LSorted[I].StartUtc <= Result[LCount - 1].EndUtc) then
    begin
      if LSorted[I].EndUtc > Result[LCount - 1].EndUtc then
        Result[LCount - 1].EndUtc := LSorted[I].EndUtc;
    end
    else
    begin
      Result[LCount] := LSorted[I];
      Inc(LCount);
    end;
  SetLength(Result, LCount);
end;

// AMinutes after local midnight of ADay (1440 is the next day's 00:00).
function ClockInstant(const AZone: IPcTimeZone; const ADay: TPcLocalDateTime;
  AMinutes: Integer): Int64;
var
  LLocal: TPcLocalDateTime;
begin
  LLocal := ADay.AddDays(AMinutes div MINUTES_PER_DAY);
  LLocal.Hour := (AMinutes mod MINUTES_PER_DAY) div 60;
  LLocal.Minute := AMinutes mod 60;
  LLocal.Second := 0;
  Result := AZone.ToUtc(LLocal, gapStartOfAfter, overlapEarlier);
end;

function WorkingSpans(const AZone: IPcTimeZone; const AWeek: TClockIntervalArray;
  const AFirstDay: TPcLocalDateTime; ADays: Integer): TSpanArray;
var
  LSpans: TSpanArray;
  LDay: TPcLocalDateTime;
  D, I, LCount: Integer;
begin
  LSpans := nil;
  SetLength(LSpans, (ADays + 2) * Length(AWeek));
  LCount := 0;
  for D := -1 to ADays do
  begin
    LDay := AFirstDay.AddDays(D);
    for I := 0 to High(AWeek) do
      if AWeek[I].Weekday = LDay.IsoWeekday then
      begin
        LSpans[LCount].StartUtc := ClockInstant(AZone, LDay, AWeek[I].StartMinute);
        LSpans[LCount].EndUtc := ClockInstant(AZone, LDay, AWeek[I].EndMinute);
        Inc(LCount);
      end;
  end;
  SetLength(LSpans, LCount);
  Result := JoinSpans(LSpans);
end;

function FreeSlots(const AWorking, ABusy: TSpanArray; ADurationMinutes, ABufferMinutes,
  AStepMinutes: Integer; AFrom, ATo, ANow: Int64): TSlotStarts;
var
  LWorking, LBusy: TSpanArray;
  LDuration, LOccupied, LStep, LStart: Int64;
  W, B, LCount: Integer;
begin
  Result := nil;
  if (ADurationMinutes <= 0) or (AStepMinutes <= 0) then
    Exit;
  LWorking := JoinSpans(AWorking);
  LBusy := JoinSpans(ABusy);
  LDuration := Int64(ADurationMinutes) * 60;
  LOccupied := LDuration + Int64(ABufferMinutes) * 60;
  LStep := Int64(AStepMinutes) * 60;
  LCount := 0;
  B := 0;
  for W := 0 to High(LWorking) do
  begin
    LStart := LWorking[W].StartUtc;
    while LStart + LDuration <= LWorking[W].EndUtc do
    begin
      // Busy spans are sorted and apart: the first that ends after this
      // start is the only one that can meet [LStart, LStart + LOccupied).
      while (B <= High(LBusy)) and (LBusy[B].EndUtc <= LStart) do
        Inc(B);
      if (LStart >= AFrom) and (LStart < ATo) and (LStart >= ANow) and
        ((B > High(LBusy)) or (LBusy[B].StartUtc >= LStart + LOccupied)) then
      begin
        if LCount = Length(Result) then
          SetLength(Result, LCount * 2 + 16);
        Result[LCount] := LStart;
        Inc(LCount);
      end;
      Inc(LStart, LStep);
    end;
  end;
  SetLength(Result, LCount);
end;

function LocalIso(const AZone: IPcTimeZone; AUtc: Int64): string;
var
  LOffset: Integer;
  LSign: Char;
begin
  LOffset := AZone.OffsetAt(AUtc);
  if LOffset < 0 then
    LSign := '-'
  else
    LSign := '+';
  LOffset := Abs(LOffset) div 60;
  Result := AZone.ToLocal(AUtc).ToString + Format('%s%.2d:%.2d',
    [LSign, LOffset div 60, LOffset mod 60]);
end;

end.
