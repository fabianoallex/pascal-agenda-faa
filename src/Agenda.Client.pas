unit Agenda.Client;

{$I agenda.inc}

{ The desktop client's calls to the api: one method per route the staff's
  screens use (decision 8 of "M6: design"), taking and returning the
  server's own DTO interfaces (the Agenda.*.Dtos units, decision 1).

  - Over Agenda.HttpClient (retries, errors as EApiError, traceparent) and
    Agenda.HttpSession (the tokens, one refresh at a time): Login starts the
    session, Logout ends it, every other call carries the access token.
  - A body is checked with the server's limits before it is sent
    (TApiSchema.Check, decision 2): EPcValidationError with the same fields
    a 400 would list, and no request.
  - A booking takes an Idempotency-Key made once per user action
    (NewIdempotencyKey), so its retries can't book twice. A move, a status
    and a cancel send the version read (If-Match: the version in quotes),
    are never retried by the client, and meet 412 when someone changed the
    appointment first (decision 7).
  - Every method takes the user action's trace id (NewTraceId), '' for a
    new trace.
  - Thread-safe once logged in: the screens call it from pool threads.
  - A DTO built here is held through its interface before it is passed
    on: FPC adds no reference for a class instance given to a const
    interface parameter, so an exception there would leak it. }

interface

uses
  SysUtils,
  PascalJsonMapper.Json,
  PascalApi.HttpTransport,
  Agenda.HttpClient,
  Agenda.HttpSession,
  Agenda.AuthDtos,
  Agenda.Appointments.Dtos,
  Agenda.Availability.Dtos,
  Agenda.Customers.Dtos,
  Agenda.Day.Dtos,
  Agenda.Professionals.Dtos,
  Agenda.Services.Dtos;

const
  /// The longest page the api gives (its lists' limit).
  CLIENT_LIST_LIMIT = 100;

type
  TAgendaClient = class
  private
    FHttp: TApiHttpClient;
    FSession: TApiSession;
    FSessionRef: IApiCredentials;
    function Call(const ARequest: TApiCall): TApiReply;
    function Request(const AMethod, APath, ATraceId: string): TApiCall;
    function ChangeAppointment(const AId: string; AVersion: Integer;
      const ABody, ATraceId: string): IAppointment;
  public
    /// ABaseUrl: the api's address (http://host:port), from the settings.
    constructor Create(const ABaseUrl: string; const ATransport: IHttpTransport);
    destructor Destroy; override;

    { the session }

    /// POST /auth/login: EApiError 401 invalid_credentials for any wrong
    /// part, 403 tenant_suspended.
    procedure Login(const ATenant, AEmail, APassword: string; const ATraceId: string = '');
    /// POST /auth/logout, then the tokens forgotten. Never raises: the
    /// program is closing; False when the api didn't answer 204.
    function Logout(const ATraceId: string = ''): Boolean;
    function LoggedIn: Boolean;
    /// A refresh was refused: the screen logs in again.
    function SessionLost: Boolean;
    function Me(const ATraceId: string = ''): IMeResponse;

    { the agenda }

    /// GET /agenda/day: ADate 'YYYY-MM-DD' (the tenant's local day);
    /// AProfessionalId '' for everyone.
    function GetDay(const ADate, AProfessionalId: string; const ATraceId: string = ''): IDay;
    /// GET /professionals/:id/availability: ADays from 1 to MAX_AVAILABILITY_DAYS.
    function GetAvailability(const AProfessionalId, AServiceId, ADate: string;
      ADays: Integer = 1; const ATraceId: string = ''): IAvailability;
    /// POST /appointments with AKey as Idempotency-Key (the same key for
    /// the same user action: a retry replays the first answer). EApiError
    /// 409 slot_unavailable when the slot was taken.
    function Book(const ABooking: IAppointmentInsert; const AKey: string;
      const ATraceId: string = ''): IAppointment;
    function GetAppointment(const AId: string; const ATraceId: string = ''): IAppointment;
    /// PATCH /appointments/:id {"startsAt"}, If-Match AVersion.
    function Move(const AId: string; AVersion: Integer; const AStartsAt: TUtcDateTime;
      const ATraceId: string = ''): IAppointment;
    /// PATCH /appointments/:id {"status"}: confirmed, done, no_show.
    function SetStatus(const AId: string; AVersion: Integer; const AStatus: string;
      const ATraceId: string = ''): IAppointment;
    /// POST /appointments/:id/cancel, If-Match AVersion.
    function Cancel(const AId: string; AVersion: Integer; const ATraceId: string = ''): IAppointment;

    { customers, and the lists a booking picks from }

    /// GET /customers?search=&page=&limit=: ASearch '' for all.
    function FindCustomers(const ASearch: string; APage, ALimit: Integer;
      out AInfo: TApiPageInfo; const ATraceId: string = ''): TCustomerArray;
    function GetCustomer(const AId: string; const ATraceId: string = ''): ICustomer;
    function CreateCustomer(const ACustomer: ICustomerInsert; const ATraceId: string = ''): ICustomer;
    /// PATCH /customers/:id: an absent member unchanged, a null one cleared.
    function UpdateCustomer(const AId: string; const AChange: ICustomerPatch;
      const ATraceId: string = ''): ICustomer;
    /// The active services (first CLIENT_LIST_LIMIT, by name).
    function ActiveServices(const ATraceId: string = ''): TServiceArray;
    /// The active professionals (first CLIENT_LIST_LIMIT, by name).
    function ActiveProfessionals(const ATraceId: string = ''): TProfessionalArray;

    property Http: TApiHttpClient read FHttp;
    property Session: TApiSession read FSession;
  end;

implementation

uses
  PascalCommon.Optionals,
  PascalCommon.Utf8,
  PascalCommon.Validators,
  PascalJsonMapper.Mapper,
  PascalApi.OpenApi;

type
  // POST /auth/refresh for the session. Holds the HTTP client without
  // owning it: TAgendaClient frees the session (and this) first.
  TAgendaRefresher = class(TInterfacedObject, IApiTokenRefresher)
  private
    FHttp: TApiHttpClient;
  public
    constructor Create(AHttp: TApiHttpClient);
    function Refresh(const ARefreshToken: string): TApiTokens;
  end;

function TokensOf(const ABody: string): TApiTokens;
var
  LTokens: ITokensResponse;
begin
  LTokens := TJsonMapper.Shared.FromJson<ITokensResponse>(ABody);
  Result.AccessToken := LTokens.AccessToken;
  Result.RefreshToken := LTokens.RefreshToken;
  Result.ExpiresInSeconds := LTokens.ExpiresIn;
end;

function PathId(const AId: string): string;
begin
  Result := PcPercentEncode(AId);
end;

{ TAgendaRefresher }

constructor TAgendaRefresher.Create(AHttp: TApiHttpClient);
begin
  inherited Create;
  FHttp := AHttp;
end;

function TAgendaRefresher.Refresh(const ARefreshToken: string): TApiTokens;
var
  LBody: TRefreshRequest;
  LKeep: IRefreshRequest;
  LRequest: TApiCall;
begin
  LBody := TRefreshRequest.Create;
  LKeep := LBody;
  LBody.RefreshToken := ARefreshToken;
  LRequest := TApiCall.Create('POST', '/auth/refresh');
  LRequest.Body := TJsonMapper.Shared.ToJson<IRefreshRequest>(LKeep);
  LRequest.Anonymous := True;
  // Never sent twice: a second refresh with a spent token revokes the
  // family (the server's reuse detection).
  LRequest.NoRetry := True;
  Result := TokensOf(FHttp.Execute(LRequest).Body);
end;

{ TAgendaClient }

constructor TAgendaClient.Create(const ABaseUrl: string; const ATransport: IHttpTransport);
begin
  inherited Create;
  FHttp := TApiHttpClient.Create(ABaseUrl, ATransport);
  FSession := TApiSession.Create(TAgendaRefresher.Create(FHttp));
  FSessionRef := FSession;
  FHttp.Credentials := FSessionRef;
end;

destructor TAgendaClient.Destroy;
begin
  if FHttp <> nil then
    FHttp.Credentials := nil;
  FSessionRef := nil;
  FSession := nil;
  FHttp.Free;
  inherited;
end;

function TAgendaClient.Request(const AMethod, APath, ATraceId: string): TApiCall;
begin
  Result := TApiCall.Create(AMethod, APath);
  Result.TraceId := ATraceId;
end;

function TAgendaClient.Call(const ARequest: TApiCall): TApiReply;
begin
  Result := FHttp.Execute(ARequest);
end;

procedure TAgendaClient.Login(const ATenant, AEmail, APassword, ATraceId: string);
var
  LBody: TLoginRequest;
  LKeep: ILoginRequest;
  LRequest: TApiCall;
begin
  LBody := TLoginRequest.Create;
  LKeep := LBody;
  LBody.Tenant := ATenant;
  LBody.Email := AEmail;
  LBody.Password := APassword;
  LRequest := Request('POST', '/auth/login', ATraceId);
  LRequest.Body := TJsonMapper.Shared.ToJson<ILoginRequest>(LKeep);
  LRequest.Anonymous := True;
  FSession.Start(TokensOf(Call(LRequest).Body));
end;

function TAgendaClient.Logout(const ATraceId: string): Boolean;
var
  LBody: TRefreshRequest;
  LKeep: IRefreshRequest;
  LRequest: TApiCall;
  LToken: string;
begin
  Result := False;
  LToken := FSession.RefreshToken;
  FSession.Clear;
  if LToken = '' then
    Exit;
  LBody := TRefreshRequest.Create;
  LKeep := LBody;
  LBody.RefreshToken := LToken;
  LRequest := Request('POST', '/auth/logout', ATraceId);
  LRequest.Body := TJsonMapper.Shared.ToJson<IRefreshRequest>(LKeep);
  LRequest.Anonymous := True;
  LRequest.NoRetry := True;
  try
    Result := Call(LRequest).Status = 204;
  except
    on Exception do
      Result := False;
  end;
end;

function TAgendaClient.LoggedIn: Boolean;
begin
  Result := FSession.RefreshToken <> '';
end;

function TAgendaClient.SessionLost: Boolean;
begin
  Result := FSession.Lost;
end;

function TAgendaClient.Me(const ATraceId: string): IMeResponse;
begin
  Result := TJsonMapper.Shared.FromJson<IMeResponse>(Call(Request('GET', '/me', ATraceId)).Body);
end;

function TAgendaClient.GetDay(const ADate, AProfessionalId, ATraceId: string): IDay;
begin
  Result := TJsonMapper.Shared.FromJson<IDay>(Call(Request('GET',
    '/agenda/day' + ApiQuery(['date', ADate, 'professional', AProfessionalId]), ATraceId)).Body);
end;

function TAgendaClient.GetAvailability(const AProfessionalId, AServiceId, ADate: string;
  ADays: Integer; const ATraceId: string): IAvailability;
begin
  Result := TJsonMapper.Shared.FromJson<IAvailability>(Call(Request('GET',
    '/professionals/' + PathId(AProfessionalId) + '/availability' +
    ApiQuery(['service', AServiceId, 'date', ADate, 'days', IntToStr(ADays)]), ATraceId)).Body);
end;

function TAgendaClient.Book(const ABooking: IAppointmentInsert; const AKey,
  ATraceId: string): IAppointment;
var
  LCheck: TPcValidation;
  LRequest: TApiCall;
begin
  LCheck := TPcValidation.Create;
  TApiSchema.Check(TypeInfo(IAppointmentInsert), ABooking, LCheck);
  LCheck.RaiseIfAny;
  LRequest := Request('POST', '/appointments', ATraceId);
  LRequest.Body := TJsonMapper.Shared.ToJson<IAppointmentInsert>(ABooking);
  LRequest.IdempotencyKey := AKey;
  Result := TJsonMapper.Shared.FromJson<IAppointment>(Call(LRequest).Body);
end;

function TAgendaClient.GetAppointment(const AId, ATraceId: string): IAppointment;
begin
  Result := TJsonMapper.Shared.FromJson<IAppointment>(
    Call(Request('GET', '/appointments/' + PathId(AId), ATraceId)).Body);
end;

function TAgendaClient.ChangeAppointment(const AId: string; AVersion: Integer;
  const ABody, ATraceId: string): IAppointment;
var
  LRequest: TApiCall;
begin
  LRequest := Request('PATCH', '/appointments/' + PathId(AId), ATraceId);
  LRequest.Body := ABody;
  LRequest.IfMatch := '"' + IntToStr(AVersion) + '"';
  Result := TJsonMapper.Shared.FromJson<IAppointment>(Call(LRequest).Body);
end;

function TAgendaClient.Move(const AId: string; AVersion: Integer;
  const AStartsAt: TUtcDateTime; const ATraceId: string): IAppointment;
var
  LChange: TAppointmentPatch;
  LKeep: IAppointmentPatch;
begin
  LChange := TAppointmentPatch.Create;
  LKeep := LChange;
  LChange.StartsAt := TOptNullString.From(JsonUtcDateTimeToStr(AStartsAt));
  Result := ChangeAppointment(AId, AVersion,
    TJsonMapper.Shared.ToJson<IAppointmentPatch>(LKeep), ATraceId);
end;

function TAgendaClient.SetStatus(const AId: string; AVersion: Integer;
  const AStatus, ATraceId: string): IAppointment;
var
  LChange: TAppointmentPatch;
  LCheck: TPcValidation;
  LKeep: IAppointmentPatch;
begin
  LChange := TAppointmentPatch.Create;
  LKeep := LChange;
  LChange.Status := TOptNullString.From(AStatus);
  LCheck := TPcValidation.Create;
  TApiSchema.Check(TypeInfo(IAppointmentPatch), LKeep, LCheck);
  LCheck.RaiseIfAny;
  Result := ChangeAppointment(AId, AVersion, TJsonMapper.Shared.ToJson<IAppointmentPatch>(LKeep),
    ATraceId);
end;

function TAgendaClient.Cancel(const AId: string; AVersion: Integer;
  const ATraceId: string): IAppointment;
var
  LRequest: TApiCall;
begin
  LRequest := Request('POST', '/appointments/' + PathId(AId) + '/cancel', ATraceId);
  LRequest.IfMatch := '"' + IntToStr(AVersion) + '"';
  Result := TJsonMapper.Shared.FromJson<IAppointment>(Call(LRequest).Body);
end;

function TAgendaClient.FindCustomers(const ASearch: string; APage, ALimit: Integer;
  out AInfo: TApiPageInfo; const ATraceId: string): TCustomerArray;
var
  LItems: string;
begin
  LItems := ReadApiPage(Call(Request('GET', '/customers' + ApiQuery(['search', ASearch,
    'page', IntToStr(APage), 'limit', IntToStr(ALimit), 'orderBy', 'name']), ATraceId)).Body, AInfo);
  Result := TJsonMapper.Shared.Deserialize<TCustomerArray>(LItems);
end;

function TAgendaClient.GetCustomer(const AId, ATraceId: string): ICustomer;
begin
  Result := TJsonMapper.Shared.FromJson<ICustomer>(
    Call(Request('GET', '/customers/' + PathId(AId), ATraceId)).Body);
end;

function TAgendaClient.CreateCustomer(const ACustomer: ICustomerInsert;
  const ATraceId: string): ICustomer;
var
  LCheck: TPcValidation;
  LRequest: TApiCall;
begin
  LCheck := TPcValidation.Create;
  TApiSchema.Check(TypeInfo(ICustomerInsert), ACustomer, LCheck);
  LCheck.RaiseIfAny;
  LRequest := Request('POST', '/customers', ATraceId);
  LRequest.Body := TJsonMapper.Shared.ToJson<ICustomerInsert>(ACustomer);
  Result := TJsonMapper.Shared.FromJson<ICustomer>(Call(LRequest).Body);
end;

function TAgendaClient.UpdateCustomer(const AId: string; const AChange: ICustomerPatch;
  const ATraceId: string): ICustomer;
var
  LCheck: TPcValidation;
  LRequest: TApiCall;
begin
  LCheck := TPcValidation.Create;
  TApiSchema.Check(TypeInfo(ICustomerPatch), AChange, LCheck);
  LCheck.RaiseIfAny;
  LRequest := Request('PATCH', '/customers/' + PathId(AId), ATraceId);
  LRequest.Body := TJsonMapper.Shared.ToJson<ICustomerPatch>(AChange);
  Result := TJsonMapper.Shared.FromJson<ICustomer>(Call(LRequest).Body);
end;

function TAgendaClient.ActiveServices(const ATraceId: string): TServiceArray;
var
  LInfo: TApiPageInfo;
begin
  Result := TJsonMapper.Shared.Deserialize<TServiceArray>(ReadApiPage(Call(Request('GET',
    '/services' + ApiQuery(['active', 'true', 'limit', IntToStr(CLIENT_LIST_LIMIT),
    'orderBy', 'name']), ATraceId)).Body, LInfo));
end;

function TAgendaClient.ActiveProfessionals(const ATraceId: string): TProfessionalArray;
var
  LInfo: TApiPageInfo;
begin
  Result := TJsonMapper.Shared.Deserialize<TProfessionalArray>(ReadApiPage(Call(Request('GET',
    '/professionals' + ApiQuery(['active', 'true', 'limit', IntToStr(CLIENT_LIST_LIMIT),
    'orderBy', 'name']), ATraceId)).Body, LInfo));
end;

end.
