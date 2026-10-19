unit Agenda.TimeOff;

{$I agenda.inc}

(* A professional's time off: a span of instants (holidays, a doctor's
  appointment) when nobody books them. DTOs, the ordering clients may ask
  for, and a repository on a tenant's scope.

  - Instants, not the local clock: "from 24 Dec 13:00 to 26 Dec 09:00" is one
    span whatever the daylight saving rules do in between. They are
    pascal-jsonmapper-faa's TUtcDateTime: ISO 8601 that must say its zone
    ("Z" or an offset), written back in UTC with "Z". Until its 0.7.0 they
    were strings checked here.
  - Whole minutes, start before end, at most MAX_SPAN_DAYS long. Spans may
    overlap: two reasons for one afternoon off harm nothing, and the
    free-slot computation (M2) subtracts each.
  - Created and deleted, not changed: a different span is a new entry.
  - The list takes from/to: the entries that overlap [from, to).
  - Every query goes through TTenantFilter.Prepare (the ${TENANT} tag), and
    names the professional: an entry is reached only through its own.

  This comment uses parenthesis-asterisk: it quotes ${TENANT}, whose brace
  would close a brace comment. *)

interface

uses
  PascalCommon.Optionals,
  PascalJsonMapper.Json,
  PascalDb.Paging,
  PascalApi.OrderBy,
  PascalApi.Dto,
  PascalApi.Tenancy;

const
  MAX_SPAN_DAYS = 366;
  MAX_REASON_CHARS = 200;

type
  ITimeOffInsert = interface(IInsertDTOBase)
    ['{EB69F22C-852D-4568-B288-0D474C51C3E1}']
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetReason: IOptString;
    property StartsAt: TUtcDateTime read GetStartsAt;
    property EndsAt: TUtcDateTime read GetEndsAt;
    property Reason: IOptString read GetReason;
  end;

  ITimeOff = interface(IResponseDTOBase)
    ['{27603AAC-EE3F-4737-B11D-A3B96B339640}']
    function GetId: string;
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetReason: INullString;
    property Id: string read GetId;
    property StartsAt: TUtcDateTime read GetStartsAt;
    property EndsAt: TUtcDateTime read GetEndsAt;
    property Reason: INullString read GetReason;
  end;

  /// GET .../time-off: page, limit, orderBy, from, to (instants).
  ITimeOffFind = interface(IFindPaginationDTOBase)
    ['{736BD646-454E-4241-B7B7-A293C7EEF347}']
    function GetFrom: IOptString;
    function GetTo: IOptString;
    property From: IOptString read GetFrom;
    property To_: IOptString read GetTo;
  end;

{$M+}
  TTimeOffInsert = class(TInsertDTOBase, ITimeOffInsert)
  private
    FStartsAt, FEndsAt: TUtcDateTime;
    FReason: IOptString;
  public
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetReason: IOptString;
  published
    property StartsAt: TUtcDateTime read FStartsAt write FStartsAt;
    property EndsAt: TUtcDateTime read FEndsAt write FEndsAt;
    property Reason: IOptString read FReason write FReason;
  end;

  TTimeOff = class(TResponseDTOBase, ITimeOff)
  private
    FId: string;
    FStartsAt, FEndsAt: TUtcDateTime;
    FReason: INullString;
  public
    function GetId: string;
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetReason: INullString;
  published
    property Id: string read FId write FId;
    property StartsAt: TUtcDateTime read FStartsAt write FStartsAt;
    property EndsAt: TUtcDateTime read FEndsAt write FEndsAt;
    property Reason: INullString read FReason write FReason;
  end;

  TTimeOffFind = class(TFindPaginationDTOBase, ITimeOffFind)
  private
    FFrom, FTo: IOptString;
  public
    function GetFrom: IOptString;
    function GetTo: IOptString;
  published
    property From: IOptString read FFrom write FFrom;
    property To_: IOptString read FTo write FTo;
  end;
{$M-}

  TTimeOffArray = TArray<ITimeOff>;

  TTimeOffRepository = class
  private
    FScope: TTenantDataScope;
  public
    constructor Create(const AScope: TTenantDataScope);
    /// ENotFoundException for an unknown professional; EValidationException
    /// for from/to that aren't instants; EOrderByException (400).
    function FindPage(const AProfessionalId: string; const AFind: ITimeOffFind;
      const APage: TPageRequest): TPage<ITimeOff>;
    /// ENotFoundException unless the professional has this entry.
    function FindById(const AProfessionalId, AId: string): ITimeOff;
    function Insert(const AProfessionalId: string; const ATimeOff: ITimeOffInsert): ITimeOff;
    procedure Delete(const AProfessionalId, AId: string);
  end;

function TimeOffOrderSpec: TOrderBySpec;

implementation

uses
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.SqlLoader,
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi,
  PascalApi.Http,
  PascalCommon.Validators,
  PascalApi.Jwt,
  PascalApi.PagedQuery,
  Agenda.Times,
  Agenda.Tokens,
  Agenda.Professionals;

function TimeOffOrderSpec: TOrderBySpec;
begin
  Result := TOrderBySpec.New
    .Allow('startsAt', 'START_UTC')
    .Default('startsAt')
    .AlwaysLast('ID');
end;

{ DTOs }

function TTimeOffInsert.GetStartsAt: TUtcDateTime;
begin
  Result := FStartsAt;
end;

function TTimeOffInsert.GetEndsAt: TUtcDateTime;
begin
  Result := FEndsAt;
end;

function TTimeOffInsert.GetReason: IOptString;
begin
  Result := TOptionals.Safe(FReason);
end;

function TTimeOff.GetId: string;
begin
  Result := FId;
end;

function TTimeOff.GetStartsAt: TUtcDateTime;
begin
  Result := FStartsAt;
end;

function TTimeOff.GetEndsAt: TUtcDateTime;
begin
  Result := FEndsAt;
end;

function TTimeOff.GetReason: INullString;
begin
  Result := TOptionals.Safe(FReason);
end;

function TTimeOffFind.GetFrom: IOptString;
begin
  Result := TOptionals.Safe(FFrom);
end;

function TTimeOffFind.GetTo: IOptString;
begin
  Result := TOptionals.Safe(FTo);
end;

{ validation }

// AText as Unix seconds; 400 naming AMember unless it is an instant.
function CheckInstant(const AText, AMember: string): Int64;
begin
  if not TryParseInstant(AText, Result) then
    raise EValidationException.Create(Format('"%s" must be an ISO 8601 date and time with ' +
      'its zone ("Z" or an offset), such as 2026-12-24T13:00:00Z.', [AMember]),
      'invalid_instant');
end;

// An end of the span: there (an absent member is 0, 1899) and whole minutes.
procedure CheckEnd(const AField: string; AUnix: Int64; var ACheck: TPcValidation);
begin
  if AUnix < 0 then
    ACheck.Fail(AField, PC_VALIDATION_REQUIRED, Format('"%s" is required.', [AField]))
  else if AUnix mod 60 <> 0 then
    ACheck.Fail(AField, 'not_whole_minutes', Format('"%s" must be whole minutes.', [AField]));
end;

function ReadTimeOff(const AResult: IQueryResult): ITimeOff;
var
  LTimeOff: TTimeOff;
begin
  LTimeOff := TTimeOff.Create;
  Result := LTimeOff;
  LTimeOff.Id := AResult.Strings['ID'];
  LTimeOff.StartsAt := UnixToUtc(AResult.Int64s['START_UTC']);
  LTimeOff.EndsAt := UnixToUtc(AResult.Int64s['END_UTC']);
  LTimeOff.Reason := AResult.NullableStrings['REASON'];
end;

{ TTimeOffRepository }

constructor TTimeOffRepository.Create(const AScope: TTenantDataScope);
begin
  inherited Create;
  FScope := AScope;
end;

function TTimeOffRepository.FindPage(const AProfessionalId: string; const AFind: ITimeOffFind;
  const APage: TPageRequest): TPage<ITimeOff>;
var
  LOrder: string;
  LArgs: TQueryArgs;

  function Filtered(const ASql: TSQLResult): TSQLResult;
  begin
    Result := ASql.ProcessTag('FROM', AFind.From.HasValue).ProcessTag('TO', AFind.To_.HasValue);
  end;

begin
  LOrder := TimeOffOrderSpec.Build(AFind.OrderBy.ValueOr(''));
  LArgs := TQueryArgs.New.Strings('PROFESSIONAL_ID', AProfessionalId);
  if AFind.From.HasValue then
    LArgs := LArgs.Int64s('FROM_UTC', CheckInstant(AFind.From.Value, 'from'));
  if AFind.To_.HasValue then
    LArgs := LArgs.Int64s('TO_UTC', CheckInstant(AFind.To_.Value, 'to'));
  RequireProfessional(FScope, AProfessionalId);
  Result := TTenantPagedQuery.Run<ITimeOff>(FScope,
    Filtered(FScope.Factory.SqlLoader['TIME_OFF.COUNT']),
    Filtered(FScope.Factory.SqlLoader['TIME_OFF.PAGE']), LOrder, APage, LArgs, ReadTimeOff);
end;

function TTimeOffRepository.FindById(const AProfessionalId, AId: string): ITimeOff;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  Result := nil;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, FScope, 'TIME_OFF.BY_ID');
  LQuery.Params.Strings['ID'] := AId;
  LQuery.Params.Strings['PROFESSIONAL_ID'] := AProfessionalId;
  LResult := LQuery.Open;
  if not LResult.Eof then
    Result := ReadTimeOff(LResult);
  if Result = nil then
    raise ENotFoundException.Create('Time off not found.');
end;

function TTimeOffRepository.Insert(const AProfessionalId: string;
  const ATimeOff: ITimeOffInsert): ITimeOff;
var
  LStart, LEnd: Int64;
  LReason: IOptNullString;
  LCheck: TPcValidation;
  LId: string;
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  // The mapper already refused a text without its zone (TUtcDateTime); an
  // absent member is 0, 1899.
  LStart := UtcToUnix(ATimeOff.StartsAt);
  LEnd := UtcToUnix(ATimeOff.EndsAt);
  // Every failing member in one 400; the span is checked once both ends are
  // valid. The reason's length is the document's, enforced at the edge.
  LCheck := TPcValidation.Create;
  CheckEnd('startsAt', LStart, LCheck);
  CheckEnd('endsAt', LEnd, LCheck);
  if LCheck.IsValid then
    if LStart >= LEnd then
      LCheck.Fail('endsAt', 'before_start', '"startsAt" must come before "endsAt".')
    else if LEnd - LStart > Int64(MAX_SPAN_DAYS) * 86400 then
      LCheck.Fail('endsAt', 'span_too_long',
        Format('Time off lasts at most %d days.', [MAX_SPAN_DAYS]));
  LCheck.RaiseIfAny;
  LReason := TOptNullString.Null;
  if ATimeOff.Reason.HasValue and (Trim(ATimeOff.Reason.Value) <> '') then
    LReason := TOptNullString.From(Trim(ATimeOff.Reason.Value));
  LId := NewId;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TouchProfessional(LQuery, FScope, AProfessionalId);
    TTenantFilter.Prepare(LQuery, FScope, 'TIME_OFF.INSERT');
    LQuery.Params.Strings['ID'] := LId;
    LQuery.Params.Strings['PROFESSIONAL_ID'] := AProfessionalId;
    LQuery.Params.Int64s['START_UTC'] := LStart;
    LQuery.Params.Int64s['END_UTC'] := LEnd;
    LQuery.Params.OptNullStrings['REASON'] := LReason;
    LQuery.Params.Int64s['CREATED_AT'] := TJwt.UnixNow;
    LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  Result := FindById(AProfessionalId, LId);
end;

procedure TTimeOffRepository.Delete(const AProfessionalId, AId: string);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LRows: Int64;
begin
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'TIME_OFF.DELETE');
    LQuery.Params.Strings['ID'] := AId;
    LQuery.Params.Strings['PROFESSIONAL_ID'] := AProfessionalId;
    LRows := LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  if LRows = 0 then
    raise ENotFoundException.Create('Time off not found.');
end;

initialization
  TJsonMapper.Shared.RenameMember(TTimeOffFind, 'To_', 'to');
  TJsonMapper.Shared.RegisterMapping<ITimeOffInsert, TTimeOffInsert>;
  TJsonMapper.Shared.RegisterMapping<ITimeOff, TTimeOff>;
  TJsonMapper.Shared.RegisterMapping<ITimeOffFind, TTimeOffFind>;
  TApiSchema.Describe(TypeInfo(ITimeOffInsert), 'A span when the professional takes no bookings')
    .Prop('StartsAt').Desc('ISO 8601 with "Z" or an offset; whole minutes')
      .Format('date-time').Example('2026-12-24T13:00:00Z')
    .Prop('EndsAt').Desc('After startsAt, at most 366 days later')
      .Format('date-time').Example('2026-12-26T12:00:00Z')
    .Prop('Reason').Desc('Optional').Example('Holidays').MaxLength(MAX_REASON_CHARS);
  TApiSchema.Describe(TypeInfo(ITimeOff), 'A professional''s time off')
    .Prop('StartsAt').Desc('UTC').Format('date-time')
    .Prop('EndsAt').Desc('UTC').Format('date-time')
    .Prop('Reason').Desc('null when none');
  TApiSchema.Describe(TypeInfo(ITimeOffFind))
    .Prop('Page').Desc('Page number, from 1')
    .Prop('Limit').Desc('Entries per page (default 20, at most 100)')
    .Prop('OrderBy').Desc(TimeOffOrderSpec.DocHint)
    .Prop('Search').Desc('Not used here')
    .Prop('From').Desc('Only entries that end after this instant (ISO 8601 with its zone)')
    .Prop('To_').Desc('Only entries that start before this instant (ISO 8601 with its zone)');

end.
