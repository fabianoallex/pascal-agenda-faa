unit Agenda.Public;

{$I agenda.inc}

(* What the public routes do for an end customer, who has no account
  (docs/design.md, M3): list a tenant's active services and professionals,
  book, and see or cancel one appointment through a signed link. The tenant
  is the request's (Agenda.PublicTenancy marked it); the work is the
  repositories', with a narrower view.

  - What a public route shows: a service's id, name, duration and price; a
    professional's id and name; an appointment without its customer or
    version. Inactive services and professionals aren't listed.
  - Booking: the customer by Agenda.Customers' FindOrInsert (the same phone,
    or email, and name; M3 decision 2), then Agenda.Appointments' Book. Two
    transactions: a booking that fails leaves a new customer behind
    (docs/design.md, "Known limits"). The booking's own members are checked
    before the customer is looked for, so a body missing them creates
    nothing.
  - The link (Agenda.SignedLinks): purpose "appointment", scope the tenant,
    resource the appointment's id, expiry its start when booked. A link that
    can't be read, signed with another key or for another appointment or
    tenant is 403 invalid_link; a good one past its expiry is 410
    link_expired. The answer carries the links again (url, cancelUrl), with
    the expiry the request came with.
  - Cancelling by link: Agenda.Appointments' CancelByLink (no If-Match; the
    notice applies; twice is fine).

  This comment uses parenthesis-asterisk, as the repositories' do. *)

interface

uses
  PascalCommon.Optionals,
  PascalJsonMapper.Json,
  PascalDb.Paging,
  PascalApi.Dto,
  PascalApi.Tenancy,
  Redis.Lock,
  Agenda.SignedLinks;

const
  LINK_PURPOSE_APPOINTMENT = 'appointment';
  CODE_INVALID_LINK = 'invalid_link';
  CODE_LINK_EXPIRED = 'link_expired';

type
  /// GET /public/{slug}/services and /professionals: page, limit, orderBy,
  /// search; always the active ones.
  IPublicFind = interface(IFindPaginationDTOBase)
    ['{434E5F33-AC22-4813-BADC-7FD8289424EB}']
  end;

  IPublicService = interface(IResponseDTOBase)
    ['{C86D4E49-41AB-4242-A51D-308EE83567A0}']
    function GetId: string;
    function GetName: string;
    function GetDurationMinutes: Integer;
    function GetPrice: Currency;
    property Id: string read GetId;
    property Name: string read GetName;
    property DurationMinutes: Integer read GetDurationMinutes;
    property Price: Currency read GetPrice;
  end;

  IPublicProfessional = interface(IResponseDTOBase)
    ['{2CC00FB3-A3DF-46DF-8A94-DEB8731F6A02}']
    function GetId: string;
    function GetName: string;
    property Id: string read GetId;
    property Name: string read GetName;
  end;

  /// POST /public/{slug}/appointments.
  IPublicBookingInsert = interface(IInsertDTOBase)
    ['{C5523A57-B858-4E91-B706-B1A5820414AA}']
    function GetProfessionalId: string;
    function GetServiceId: string;
    function GetStartsAt: TUtcDateTime;
    function GetName: string;
    function GetPhone: IOptString;
    function GetEmail: IOptString;
    property ProfessionalId: string read GetProfessionalId;
    property ServiceId: string read GetServiceId;
    property StartsAt: TUtcDateTime read GetStartsAt;
    property Name: string read GetName;
    property Phone: IOptString read GetPhone;
    property Email: IOptString read GetEmail;
  end;

  IPublicAppointment = interface(IResponseDTOBase)
    ['{6F0C05E7-C713-46F6-BAE7-31E3A690F8B4}']
    function GetId: string;
    function GetProfessionalId: string;
    function GetServiceId: string;
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetStatus: string;
    function GetUrl: string;
    function GetCancelUrl: string;
    property Id: string read GetId;
    property ProfessionalId: string read GetProfessionalId;
    property ServiceId: string read GetServiceId;
    property StartsAt: TUtcDateTime read GetStartsAt;
    property EndsAt: TUtcDateTime read GetEndsAt;
    property Status: string read GetStatus;
    property Url: string read GetUrl;
    property CancelUrl: string read GetCancelUrl;
  end;

{$M+}
  TPublicFind = class(TFindPaginationDTOBase, IPublicFind)
  end;

  TPublicService = class(TResponseDTOBase, IPublicService)
  private
    FId, FName: string;
    FDurationMinutes: Integer;
    FPrice: Currency;
  public
    function GetId: string;
    function GetName: string;
    function GetDurationMinutes: Integer;
    function GetPrice: Currency;
  published
    property Id: string read FId write FId;
    property Name: string read FName write FName;
    property DurationMinutes: Integer read FDurationMinutes write FDurationMinutes;
    property Price: Currency read FPrice write FPrice;
  end;

  TPublicProfessional = class(TResponseDTOBase, IPublicProfessional)
  private
    FId, FName: string;
  public
    function GetId: string;
    function GetName: string;
  published
    property Id: string read FId write FId;
    property Name: string read FName write FName;
  end;

  TPublicBookingInsert = class(TInsertDTOBase, IPublicBookingInsert)
  private
    FProfessionalId, FServiceId, FName: string;
    FStartsAt: TUtcDateTime;
    FPhone, FEmail: IOptString;
  public
    function GetProfessionalId: string;
    function GetServiceId: string;
    function GetStartsAt: TUtcDateTime;
    function GetName: string;
    function GetPhone: IOptString;
    function GetEmail: IOptString;
  published
    property ProfessionalId: string read FProfessionalId write FProfessionalId;
    property ServiceId: string read FServiceId write FServiceId;
    property StartsAt: TUtcDateTime read FStartsAt write FStartsAt;
    property Name: string read FName write FName;
    property Phone: IOptString read FPhone write FPhone;
    property Email: IOptString read FEmail write FEmail;
  end;

  TPublicAppointment = class(TResponseDTOBase, IPublicAppointment)
  private
    FId, FProfessionalId, FServiceId, FStatus, FUrl, FCancelUrl: string;
    FStartsAt, FEndsAt: TUtcDateTime;
  public
    function GetId: string;
    function GetProfessionalId: string;
    function GetServiceId: string;
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetStatus: string;
    function GetUrl: string;
    function GetCancelUrl: string;
  published
    property Id: string read FId write FId;
    property ProfessionalId: string read FProfessionalId write FProfessionalId;
    property ServiceId: string read FServiceId write FServiceId;
    property StartsAt: TUtcDateTime read FStartsAt write FStartsAt;
    property EndsAt: TUtcDateTime read FEndsAt write FEndsAt;
    property Status: string read FStatus write FStatus;
    property Url: string read FUrl write FUrl;
    property CancelUrl: string read FCancelUrl write FCancelUrl;
  end;
{$M-}

  // The same types as TPage<...>.Items (E2008 on Delphi otherwise), and
  // names for Serialize<>.
  TPublicServiceArray = TArray<IPublicService>;
  TPublicProfessionalArray = TArray<IPublicProfessional>;

  TPublicAgenda = class
  private
    FScope: TTenantDataScope;
    FLinks: TSignedLinks;
    FLock: TRedisLock;
    FBaseUrl: string;
    function ToPublic(const AId, AProfessionalId, AServiceId, AStatus: string;
      AStartsAt, AEndsAt: TUtcDateTime; AExpires: Int64): IPublicAppointment;
    function VerifiedLink(const AId, AExpires, ASignature: string; ANow: Int64): Int64;
  public
    /// AScope: the request's tenant (its Discriminator is the tenant id,
    /// the link's scope and the path's slug). ALinks and ALock (nil: none)
    /// are not owned. ABaseUrl: what goes before "/public/..." in a link
    /// ('' for a path).
    constructor Create(const AScope: TTenantDataScope; ALinks: TSignedLinks; ALock: TRedisLock;
      const ABaseUrl: string);
    function Services(const AFind: IPublicFind; const APage: TPageRequest): TPage<IPublicService>;
    function Professionals(const AFind: IPublicFind;
      const APage: TPageRequest): TPage<IPublicProfessional>;
    /// The appointment and its links. 400 for the body (the booking's
    /// members, then the customer's: contact_required), and the booking's
    /// own answers (Agenda.Appointments.Book).
    function Book(const AInsert: IPublicBookingInsert; ANow: Int64): IPublicAppointment;
    /// The appointment a link names. 403 invalid_link, 410 link_expired, 404.
    function Show(const AId, AExpires, ASignature: string; ANow: Int64): IPublicAppointment;
    /// Cancels it: the link's answers, then CancelByLink's.
    function Cancel(const AId, AExpires, ASignature: string; ANow: Int64): IPublicAppointment;
  end;

implementation

uses
  SysUtils,
  PascalCommon.Validators,
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi,
  PascalApi.Http,
  Agenda.Times,
  Agenda.Services,
  Agenda.Professionals,
  Agenda.Customers,
  Agenda.Appointments;

{ DTOs }

function TPublicService.GetId: string;
begin
  Result := FId;
end;

function TPublicService.GetName: string;
begin
  Result := FName;
end;

function TPublicService.GetDurationMinutes: Integer;
begin
  Result := FDurationMinutes;
end;

function TPublicService.GetPrice: Currency;
begin
  Result := FPrice;
end;

function TPublicProfessional.GetId: string;
begin
  Result := FId;
end;

function TPublicProfessional.GetName: string;
begin
  Result := FName;
end;

function TPublicBookingInsert.GetProfessionalId: string;
begin
  Result := FProfessionalId;
end;

function TPublicBookingInsert.GetServiceId: string;
begin
  Result := FServiceId;
end;

function TPublicBookingInsert.GetStartsAt: TUtcDateTime;
begin
  Result := FStartsAt;
end;

function TPublicBookingInsert.GetName: string;
begin
  Result := FName;
end;

function TPublicBookingInsert.GetPhone: IOptString;
begin
  Result := TOptionals.Safe(FPhone);
end;

function TPublicBookingInsert.GetEmail: IOptString;
begin
  Result := TOptionals.Safe(FEmail);
end;

function TPublicAppointment.GetId: string;
begin
  Result := FId;
end;

function TPublicAppointment.GetProfessionalId: string;
begin
  Result := FProfessionalId;
end;

function TPublicAppointment.GetServiceId: string;
begin
  Result := FServiceId;
end;

function TPublicAppointment.GetStartsAt: TUtcDateTime;
begin
  Result := FStartsAt;
end;

function TPublicAppointment.GetEndsAt: TUtcDateTime;
begin
  Result := FEndsAt;
end;

function TPublicAppointment.GetStatus: string;
begin
  Result := FStatus;
end;

function TPublicAppointment.GetUrl: string;
begin
  Result := FUrl;
end;

function TPublicAppointment.GetCancelUrl: string;
begin
  Result := FCancelUrl;
end;

{ TPublicAgenda }

constructor TPublicAgenda.Create(const AScope: TTenantDataScope; ALinks: TSignedLinks;
  ALock: TRedisLock; const ABaseUrl: string);
begin
  inherited Create;
  if ALinks = nil then
    raise EArgumentException.Create('TPublicAgenda.Create: no link keys');
  FScope := AScope;
  FLinks := ALinks;
  FLock := ALock;
  FBaseUrl := ABaseUrl;
end;

function TPublicAgenda.Services(const AFind: IPublicFind;
  const APage: TPageRequest): TPage<IPublicService>;
var
  LFill: TServiceFind;
  LFind: IServiceFind;
  LRepo: TServiceRepository;
  LPage: TPage<IService>;
  LItem: TPublicService;
  I: Integer;
begin
  // The client's paging and search, and only the active ones.
  LFill := TServiceFind.Create;
  LFind := LFill;
  LFill.Page := AFind.Page;
  LFill.Limit := AFind.Limit;
  LFill.OrderBy := AFind.OrderBy;
  LFill.Search := AFind.Search;
  LFill.Active := TOptNullBoolean.From(True) as IOptBoolean;
  LRepo := TServiceRepository.Create(FScope);
  try
    LPage := LRepo.FindPage(LFind, APage);
  finally
    LRepo.Free;
  end;
  Result.Meta := LPage.Meta;
  Result.Items := nil;
  SetLength(Result.Items, Length(LPage.Items));
  for I := 0 to High(LPage.Items) do
  begin
    LItem := TPublicService.Create;
    Result.Items[I] := LItem;
    LItem.Id := LPage.Items[I].Id;
    LItem.Name := LPage.Items[I].Name;
    LItem.DurationMinutes := LPage.Items[I].DurationMinutes;
    LItem.Price := LPage.Items[I].Price;
  end;
end;

function TPublicAgenda.Professionals(const AFind: IPublicFind;
  const APage: TPageRequest): TPage<IPublicProfessional>;
var
  LFill: TProfessionalFind;
  LFind: IProfessionalFind;
  LRepo: TProfessionalRepository;
  LPage: TPage<IProfessional>;
  LItem: TPublicProfessional;
  I: Integer;
begin
  LFill := TProfessionalFind.Create;
  LFind := LFill;
  LFill.Page := AFind.Page;
  LFill.Limit := AFind.Limit;
  LFill.OrderBy := AFind.OrderBy;
  LFill.Search := AFind.Search;
  LFill.Active := TOptNullBoolean.From(True) as IOptBoolean;
  LRepo := TProfessionalRepository.Create(FScope);
  try
    LPage := LRepo.FindPage(LFind, APage);
  finally
    LRepo.Free;
  end;
  Result.Meta := LPage.Meta;
  Result.Items := nil;
  SetLength(Result.Items, Length(LPage.Items));
  for I := 0 to High(LPage.Items) do
  begin
    LItem := TPublicProfessional.Create;
    Result.Items[I] := LItem;
    LItem.Id := LPage.Items[I].Id;
    LItem.Name := LPage.Items[I].Name;
  end;
end;

function TPublicAgenda.ToPublic(const AId, AProfessionalId, AServiceId, AStatus: string;
  AStartsAt, AEndsAt: TUtcDateTime; AExpires: Int64): IPublicAppointment;
var
  LDto: TPublicAppointment;
  LPath, LQuery: string;
begin
  LDto := TPublicAppointment.Create;
  Result := LDto;
  LDto.Id := AId;
  LDto.ProfessionalId := AProfessionalId;
  LDto.ServiceId := AServiceId;
  LDto.StartsAt := AStartsAt;
  LDto.EndsAt := AEndsAt;
  LDto.Status := AStatus;
  LPath := FBaseUrl + '/public/' + FScope.Discriminator + '/appointments/' + AId;
  LQuery := FLinks.Query(FScope.Discriminator, LINK_PURPOSE_APPOINTMENT, AId, AExpires);
  LDto.Url := LPath + '?' + LQuery;
  LDto.CancelUrl := LPath + '/cancel?' + LQuery;
end;

function TPublicAgenda.Book(const AInsert: IPublicBookingInsert;
  ANow: Int64): IPublicAppointment;
var
  LCheck: TPcValidation;
  LCustomerFill: TCustomerInsert;
  LCustomerIntf: ICustomerInsert;
  LCustomers: TCustomerRepository;
  LCustomer: ICustomer;
  LFill: TAppointmentInsert;
  LInsert: IAppointmentInsert;
  LRepo: TAppointmentRepository;
  LBooked: IAppointment;

  procedure Required(const AValue, AField: string);
  begin
    if Trim(AValue) = '' then
      LCheck.Fail(AField, PC_VALIDATION_REQUIRED, Format('"%s" is required.', [AField]));
  end;

begin
  // The booking's members first: a body without them creates no customer.
  // (A member absent is 0 for the start, 1899.)
  LCheck := TPcValidation.Create;
  Required(AInsert.ProfessionalId, 'professionalId');
  Required(AInsert.ServiceId, 'serviceId');
  if UtcToUnix(AInsert.StartsAt) < 0 then
    LCheck.Fail('startsAt', PC_VALIDATION_REQUIRED, '"startsAt" is required.');
  LCheck.RaiseIfAny;

  LCustomerFill := TCustomerInsert.Create;
  LCustomerIntf := LCustomerFill;
  LCustomerFill.Name := AInsert.Name;
  LCustomerFill.Phone := AInsert.Phone;
  LCustomerFill.Email := AInsert.Email;
  LCustomers := TCustomerRepository.Create(FScope);
  try
    LCustomer := LCustomers.FindOrInsert(LCustomerIntf);
  finally
    LCustomers.Free;
  end;

  LFill := TAppointmentInsert.Create;
  LInsert := LFill;
  LFill.ProfessionalId := AInsert.ProfessionalId;
  LFill.ServiceId := AInsert.ServiceId;
  LFill.CustomerId := LCustomer.Id;
  LFill.StartsAt := AInsert.StartsAt;
  LRepo := TAppointmentRepository.Create(FScope, FLock);
  try
    LBooked := LRepo.Book(LInsert, ANow);
  finally
    LRepo.Free;
  end;
  // The link lives until the appointment starts.
  Result := ToPublic(LBooked.Id, LBooked.ProfessionalId, LBooked.ServiceId, LBooked.Status,
    LBooked.StartsAt, LBooked.EndsAt, UtcToUnix(LBooked.StartsAt));
end;

// The link's expiry, once its signature is right and it hasn't expired.
function TPublicAgenda.VerifiedLink(const AId, AExpires, ASignature: string;
  ANow: Int64): Int64;
var
  LCheck: TSignedLinkCheck;
begin
  if not TryParseLinkExpiry(AExpires, Result) then
    LCheck := lsMalformed
  else
    LCheck := FLinks.Verify(FScope.Discriminator, LINK_PURPOSE_APPOINTMENT, AId, Result,
      ASignature, ANow);
  case LCheck of
    lsOk: ;
    lsExpired:
      raise EHttpException.Create(410, 'This link has expired.', CODE_LINK_EXPIRED);
  else
    raise EHttpException.Create(403, 'This link is not valid.', CODE_INVALID_LINK);
  end;
end;

function TPublicAgenda.Show(const AId, AExpires, ASignature: string;
  ANow: Int64): IPublicAppointment;
var
  LExpires: Int64;
  LRepo: TAppointmentRepository;
  LFound: IAppointment;
begin
  LExpires := VerifiedLink(AId, AExpires, ASignature, ANow);
  LRepo := TAppointmentRepository.Create(FScope);
  try
    LFound := LRepo.FindById(AId);
  finally
    LRepo.Free;
  end;
  Result := ToPublic(LFound.Id, LFound.ProfessionalId, LFound.ServiceId, LFound.Status,
    LFound.StartsAt, LFound.EndsAt, LExpires);
end;

function TPublicAgenda.Cancel(const AId, AExpires, ASignature: string;
  ANow: Int64): IPublicAppointment;
var
  LExpires: Int64;
  LRepo: TAppointmentRepository;
  LCancelled: IAppointment;
begin
  LExpires := VerifiedLink(AId, AExpires, ASignature, ANow);
  LRepo := TAppointmentRepository.Create(FScope);
  try
    LCancelled := LRepo.CancelByLink(AId, ANow);
  finally
    LRepo.Free;
  end;
  Result := ToPublic(LCancelled.Id, LCancelled.ProfessionalId, LCancelled.ServiceId,
    LCancelled.Status, LCancelled.StartsAt, LCancelled.EndsAt, LExpires);
end;

initialization
  TJsonMapper.Shared.RegisterMapping<IPublicFind, TPublicFind>;
  TJsonMapper.Shared.RegisterMapping<IPublicService, TPublicService>;
  TJsonMapper.Shared.RegisterMapping<IPublicProfessional, TPublicProfessional>;
  TJsonMapper.Shared.RegisterMapping<IPublicBookingInsert, TPublicBookingInsert>;
  TJsonMapper.Shared.RegisterMapping<IPublicAppointment, TPublicAppointment>;
  TApiSchema.Describe(TypeInfo(IPublicFind))
    .Prop('Page').Desc('Page number, from 1')
    .Prop('Limit').Desc('Entries per page (default 20, at most 100)')
    .Prop('OrderBy').Desc('Services: name, duration or price; professionals: name or ' +
      'createdAt. "-" in front for descending')
    .Prop('Search').Desc('Part of the name, ignoring case and accents');
  TApiSchema.Describe(TypeInfo(IPublicService), 'A service the tenant offers')
    .Prop('DurationMinutes').Desc('How long it takes')
    .Prop('Price').Example('80.00');
  TApiSchema.Describe(TypeInfo(IPublicProfessional), 'A professional of the tenant');
  TApiSchema.Describe(TypeInfo(IPublicBookingInsert), 'A booking by the customer')
    .Prop('ProfessionalId').Desc('The professional''s id')
    .Prop('ServiceId').Desc('The service''s id')
    .Prop('StartsAt').Desc('A start the professional''s availability lists')
      .Format('date-time').Example('2026-11-02T12:00:00Z')
    .Prop('Name').Desc('The customer''s name')
    .Prop('Phone').Desc('A phone or an email is required').Example('+55 11 98765-4321')
    .Prop('Email').Desc('A phone or an email is required').Example('bia@example.com');
  TApiSchema.Describe(TypeInfo(IPublicAppointment), 'An appointment, as its customer sees it')
    .Prop('StartsAt').Desc('UTC').Format('date-time')
    .Prop('EndsAt').Desc('UTC: the service''s end').Format('date-time')
    .Prop('Status').Desc('booked, confirmed, cancelled, done or no_show')
    .Prop('Url').Desc('GET: this appointment, with no account; valid until it starts')
    .Prop('CancelUrl').Desc('POST: cancels it, within the tenant''s notice');

end.
