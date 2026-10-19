unit Agenda.WorkingHours;

{$I agenda.inc}

(* A professional's working hours: a week of intervals on the tenant's local
  clock ({"weekday":1,"from":"09:00","to":"12:00"}, ISO weekday, 1 = Monday).
  DTOs and a repository on a tenant's scope.

  - The week is read and replaced whole (GET and PUT): a schedule is edited
    as one thing, and one write can't leave half of it. The PUT checks the
    week first (Agenda.Times' WeekProblem: times on 5-minute steps, no
    overlap within a day) and writes it in one transaction that starts by
    touching the professional's row (TouchProfessional: a 404, and on
    PostgreSQL a lock, so two PUTs don't mix their rows).
  - Local clock, not UTC: "09:00 on Mondays" stays 09:00 across a daylight
    saving change; turning it into instants is the free-slot computation's
    work (M2), in the tenant's time zone.
  - Every query goes through TTenantFilter.Prepare (the ${TENANT} tag).

  This comment uses parenthesis-asterisk: it quotes ${TENANT}, whose brace
  would close a brace comment. *)

interface

uses
  PascalApi.Dto,
  PascalApi.Tenancy;

type
  IWorkingInterval = interface(IDTOBase)
    ['{56B4C983-5213-48C1-AA5E-D9969462AB54}']
    function GetWeekday: Integer;
    function GetFrom: string;
    function GetTo: string;
    property Weekday: Integer read GetWeekday;
    property From: string read GetFrom;
    property To_: string read GetTo;
  end;

  TWorkingIntervalArray = TArray<IWorkingInterval>;

  /// PUT: the whole week; [] leaves the professional with no hours.
  IWorkingWeekPut = interface(IUpdateDTOBase)
    ['{85CD60CE-D05A-47B9-8B07-E1681A51B5E2}']
    function GetIntervals: TWorkingIntervalArray;
    property Intervals: TWorkingIntervalArray read GetIntervals;
  end;

  IWorkingWeek = interface(IResponseDTOBase)
    ['{D2F47C6E-CF76-41A0-8B34-08CCDEDB2887}']
    function GetIntervals: TWorkingIntervalArray;
    property Intervals: TWorkingIntervalArray read GetIntervals;
  end;

{$M+}
  TWorkingInterval = class(TDTOBase, IWorkingInterval)
  private
    FWeekday: Integer;
    FFrom, FTo: string;
  public
    function GetWeekday: Integer;
    function GetFrom: string;
    function GetTo: string;
  published
    property Weekday: Integer read FWeekday write FWeekday;
    property From: string read FFrom write FFrom;
    property To_: string read FTo write FTo;
  end;

  TWorkingWeekPut = class(TUpdateDTOBase, IWorkingWeekPut)
  private
    FIntervals: TWorkingIntervalArray;
  public
    function GetIntervals: TWorkingIntervalArray;
  published
    property Intervals: TWorkingIntervalArray read FIntervals write FIntervals;
  end;

  TWorkingWeek = class(TResponseDTOBase, IWorkingWeek)
  private
    FIntervals: TWorkingIntervalArray;
  public
    function GetIntervals: TWorkingIntervalArray;
  published
    property Intervals: TWorkingIntervalArray read FIntervals write FIntervals;
  end;
{$M-}

  TWorkingHoursRepository = class
  private
    FScope: TTenantDataScope;
  public
    constructor Create(const AScope: TTenantDataScope);
    /// ENotFoundException when the tenant has no such professional.
    function Get(const AProfessionalId: string): IWorkingWeek;
    /// EValidationException for an invalid week; ENotFoundException as Get.
    function Replace(const AProfessionalId: string; const AWeek: IWorkingWeekPut): IWorkingWeek;
  end;

implementation

uses
  SysUtils,
  PascalDb.Interfaces,
  PascalJsonMapper.Mapper,
  PascalApi.OpenApi,
  PascalApi.Http,
  Agenda.Times,
  Agenda.Professionals;

{ DTOs }

function TWorkingInterval.GetWeekday: Integer;
begin
  Result := FWeekday;
end;

function TWorkingInterval.GetFrom: string;
begin
  Result := FFrom;
end;

function TWorkingInterval.GetTo: string;
begin
  Result := FTo;
end;

function TWorkingWeekPut.GetIntervals: TWorkingIntervalArray;
begin
  Result := FIntervals;
end;

function TWorkingWeek.GetIntervals: TWorkingIntervalArray;
begin
  Result := FIntervals;
end;

{ TWorkingHoursRepository }

constructor TWorkingHoursRepository.Create(const AScope: TTenantDataScope);
begin
  inherited Create;
  FScope := AScope;
end;

function TWorkingHoursRepository.Get(const AProfessionalId: string): IWorkingWeek;
var
  LWeek: TWorkingWeek;
  LItem: TWorkingInterval;
  LItems: TWorkingIntervalArray;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
  LCount: Integer;
begin
  RequireProfessional(FScope, AProfessionalId);
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, FScope, 'WORKING_HOURS.BY_PROFESSIONAL');
  LQuery.Params.Strings['PROFESSIONAL_ID'] := AProfessionalId;
  LResult := LQuery.Open;
  LItems := nil;
  SetLength(LItems, LResult.RecordCount);
  LCount := 0;
  while not LResult.Eof do
  begin
    LItem := TWorkingInterval.Create;
    LItems[LCount] := LItem;
    LItem.Weekday := LResult.Integers['WEEKDAY'];
    LItem.From := ClockToStr(LResult.Integers['START_MINUTE']);
    LItem.To_ := ClockToStr(LResult.Integers['END_MINUTE']);
    Inc(LCount);
    LResult.Next;
  end;
  SetLength(LItems, LCount);
  LWeek := TWorkingWeek.Create;
  Result := LWeek;
  LWeek.Intervals := LItems;
end;

// The intervals as minutes; 400 for a member that isn't one.
function ReadWeek(const AWeek: IWorkingWeekPut): TClockIntervalArray;
var
  LItems: TWorkingIntervalArray;
  I: Integer;
begin
  LItems := AWeek.Intervals;
  Result := nil;
  SetLength(Result, Length(LItems));
  for I := 0 to High(LItems) do
  begin
    if LItems[I] = nil then
      raise EValidationException.CreateFmt('intervals[%d]: an object is expected.', [I]);
    Result[I].Weekday := LItems[I].Weekday;
    if not TryParseClock(LItems[I].From, Result[I].StartMinute) then
      raise EValidationException.CreateFmt('intervals[%d]: "from" must be HH:MM.', [I]);
    if not TryParseClock(LItems[I].To_, Result[I].EndMinute) then
      raise EValidationException.CreateFmt('intervals[%d]: "to" must be HH:MM.', [I]);
  end;
end;

function TWorkingHoursRepository.Replace(const AProfessionalId: string;
  const AWeek: IWorkingWeekPut): IWorkingWeek;
var
  LWeek: TClockIntervalArray;
  LProblem: string;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  I: Integer;
begin
  LWeek := ReadWeek(AWeek);
  LProblem := WeekProblem(LWeek);
  if LProblem <> '' then
    raise EValidationException.Create(LProblem, 'invalid_week');
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TouchProfessional(LQuery, FScope, AProfessionalId);
    TTenantFilter.Prepare(LQuery, FScope, 'WORKING_HOURS.DELETE_ALL');
    LQuery.Params.Strings['PROFESSIONAL_ID'] := AProfessionalId;
    LQuery.ExecSql;
    for I := 0 to High(LWeek) do
    begin
      TTenantFilter.Prepare(LQuery, FScope, 'WORKING_HOURS.INSERT');
      LQuery.Params.Strings['PROFESSIONAL_ID'] := AProfessionalId;
      LQuery.Params.Integers['WEEKDAY'] := LWeek[I].Weekday;
      LQuery.Params.Integers['START_MINUTE'] := LWeek[I].StartMinute;
      LQuery.Params.Integers['END_MINUTE'] := LWeek[I].EndMinute;
      LQuery.ExecSql;
    end;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  Result := Get(AProfessionalId);
end;

initialization
  // "to" is a Pascal keyword: the property is To_, the JSON member "to".
  TJsonMapper.Shared.RenameMember(TWorkingInterval, 'To_', 'to');
  TJsonMapper.Shared.RegisterMapping<IWorkingInterval, TWorkingInterval>;
  TJsonMapper.Shared.RegisterMapping<IWorkingWeekPut, TWorkingWeekPut>;
  TJsonMapper.Shared.RegisterMapping<IWorkingWeek, TWorkingWeek>;
  TApiSchema.Describe(TypeInfo(IWorkingInterval), 'Hours on one weekday, the tenant''s local time')
    .Prop('Weekday').Desc('ISO: 1 = Monday ... 7 = Sunday').Example('1').Minimum(1).Maximum(7)
    .Prop('From').Desc('HH:MM, a multiple of 5 minutes').Example('09:00')
    .Prop('To_').Desc('HH:MM, after "from"; 24:00 for midnight').Example('12:00');
  TApiSchema.Describe(TypeInfo(IWorkingWeekPut), 'The whole week; it replaces the stored one')
    .Prop('Intervals').Desc('No two of one weekday overlap; [] for no hours');
  TApiSchema.Describe(TypeInfo(IWorkingWeek), 'A professional''s week')
    .Prop('Intervals').Desc('By weekday, then start');

end.
