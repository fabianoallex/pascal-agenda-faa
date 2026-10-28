unit Agenda.Appointments.Dtos;

{$I agenda.inc}

{ Appointments: what a client sends and reads (a booking, a change, an
  appointment, the list's filter), the statuses and the error codes.

  Shared by the api and the desktop client: it needs pascal-common-faa,
  pascal-jsonmapper-faa and pascal-api-infra-faa's PascalApi.Dto and
  PascalApi.OpenApi only, never the database. The TApiSchema.Describe
  below gives the server's OpenAPI document and the limits both sides
  check (TApiSchema.Check). }

interface

uses
  PascalCommon.Optionals,
  PascalJsonMapper.Json,
  PascalApi.OrderBy,
  PascalApi.Dto;

const
  STATUS_BOOKED = 'booked';
  STATUS_CONFIRMED = 'confirmed';
  /// Through POST /appointments/{id}/cancel only, never PATCH.
  STATUS_CANCELLED = 'cancelled';
  STATUS_DONE = 'done';
  STATUS_NO_SHOW = 'no_show';
  CODE_SLOT_UNAVAILABLE = 'slot_unavailable';
  CODE_APPOINTMENT_CLOSED = 'appointment_closed';
  CODE_NOT_STARTED = 'not_started';
  CODE_CANCEL_NOTICE_PASSED = 'cancel_notice_passed';
  CODE_USE_CANCEL = 'use_cancel';
  CODE_APPOINTMENT_CHANGED = 'appointment_changed';

type
  IAppointmentInsert = interface(IInsertDTOBase)
    ['{2D83BB82-ED6F-43A3-B601-9AF86720EB06}']
    function GetProfessionalId: string;
    function GetServiceId: string;
    function GetCustomerId: string;
    function GetStartsAt: TUtcDateTime;
    property ProfessionalId: string read GetProfessionalId;
    property ServiceId: string read GetServiceId;
    property CustomerId: string read GetCustomerId;
    property StartsAt: TUtcDateTime read GetStartsAt;
  end;

  IAppointment = interface(IResponseDTOBase)
    ['{58BB9DF7-A936-484F-BD7A-941641B00146}']
    function GetId: string;
    function GetProfessionalId: string;
    function GetServiceId: string;
    function GetCustomerId: string;
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetStatus: string;
    function GetVersion: Integer;
    property Id: string read GetId;
    property ProfessionalId: string read GetProfessionalId;
    property ServiceId: string read GetServiceId;
    property CustomerId: string read GetCustomerId;
    property StartsAt: TUtcDateTime read GetStartsAt;
    property EndsAt: TUtcDateTime read GetEndsAt;
    property Status: string read GetStatus;
    property Version: Integer read GetVersion;
  end;

  /// PATCH /appointments/:id: the members that came change.
  IAppointmentPatch = interface(IUpdateDTOBase)
    ['{6C0E5F3B-9A41-4C7D-8E25-3B1F0A7D9C64}']
    function GetStartsAt: IOptString;
    function GetStatus: IOptString;
    property StartsAt: IOptString read GetStartsAt;
    property Status: IOptString read GetStatus;
  end;

  /// GET /appointments: page, limit, orderBy, professional, status, from, to
  /// (instants: the appointments that overlap [from, to)).
  IAppointmentFind = interface(IFindPaginationDTOBase)
    ['{E01B503D-1EC1-41F7-992D-0F80D2C3F473}']
    function GetProfessional: IOptString;
    function GetStatus: IOptString;
    function GetFrom: IOptString;
    function GetTo: IOptString;
    property Professional: IOptString read GetProfessional;
    property Status: IOptString read GetStatus;
    property From: IOptString read GetFrom;
    property To_: IOptString read GetTo;
  end;

{$M+}
  TAppointmentInsert = class(TInsertDTOBase, IAppointmentInsert)
  private
    FProfessionalId, FServiceId, FCustomerId: string;
    FStartsAt: TUtcDateTime;
  public
    function GetProfessionalId: string;
    function GetServiceId: string;
    function GetCustomerId: string;
    function GetStartsAt: TUtcDateTime;
  published
    property ProfessionalId: string read FProfessionalId write FProfessionalId;
    property ServiceId: string read FServiceId write FServiceId;
    property CustomerId: string read FCustomerId write FCustomerId;
    property StartsAt: TUtcDateTime read FStartsAt write FStartsAt;
  end;

  TAppointmentPatch = class(TUpdateDTOBase, IAppointmentPatch)
  private
    FStartsAt, FStatus: IOptString;
  public
    function GetStartsAt: IOptString;
    function GetStatus: IOptString;
  published
    property StartsAt: IOptString read FStartsAt write FStartsAt;
    property Status: IOptString read FStatus write FStatus;
  end;

  TAppointment = class(TResponseDTOBase, IAppointment)
  private
    FId, FProfessionalId, FServiceId, FCustomerId, FStatus: string;
    FStartsAt, FEndsAt: TUtcDateTime;
    FVersion: Integer;
  public
    function GetId: string;
    function GetProfessionalId: string;
    function GetServiceId: string;
    function GetCustomerId: string;
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetStatus: string;
    function GetVersion: Integer;
  published
    property Id: string read FId write FId;
    property ProfessionalId: string read FProfessionalId write FProfessionalId;
    property ServiceId: string read FServiceId write FServiceId;
    property CustomerId: string read FCustomerId write FCustomerId;
    property StartsAt: TUtcDateTime read FStartsAt write FStartsAt;
    property EndsAt: TUtcDateTime read FEndsAt write FEndsAt;
    property Status: string read FStatus write FStatus;
    property Version: Integer read FVersion write FVersion;
  end;

  TAppointmentFind = class(TFindPaginationDTOBase, IAppointmentFind)
  private
    FProfessional, FStatus, FFrom, FTo: IOptString;
  public
    function GetProfessional: IOptString;
    function GetStatus: IOptString;
    function GetFrom: IOptString;
    function GetTo: IOptString;
  published
    property Professional: IOptString read FProfessional write FProfessional;
    property Status: IOptString read FStatus write FStatus;
    property From: IOptString read FFrom write FFrom;
    property To_: IOptString read FTo write FTo;
  end;
{$M-}

  TAppointmentArray = TArray<IAppointment>;

/// The fields the list may be ordered by (orderBy).
function AppointmentOrderSpec: TOrderBySpec;

implementation

uses
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi;

function AppointmentOrderSpec: TOrderBySpec;
begin
  Result := TOrderBySpec.New
    .Allow('startsAt', 'START_UTC')
    .Default('startsAt')
    .AlwaysLast('ID');
end;

{ DTOs }

function TAppointmentInsert.GetProfessionalId: string;
begin
  Result := FProfessionalId;
end;

function TAppointmentInsert.GetServiceId: string;
begin
  Result := FServiceId;
end;

function TAppointmentInsert.GetCustomerId: string;
begin
  Result := FCustomerId;
end;

function TAppointmentInsert.GetStartsAt: TUtcDateTime;
begin
  Result := FStartsAt;
end;

function TAppointmentPatch.GetStartsAt: IOptString;
begin
  Result := TOptionals.Safe(FStartsAt);
end;

function TAppointmentPatch.GetStatus: IOptString;
begin
  Result := TOptionals.Safe(FStatus);
end;

function TAppointment.GetId: string;
begin
  Result := FId;
end;

function TAppointment.GetProfessionalId: string;
begin
  Result := FProfessionalId;
end;

function TAppointment.GetServiceId: string;
begin
  Result := FServiceId;
end;

function TAppointment.GetCustomerId: string;
begin
  Result := FCustomerId;
end;

function TAppointment.GetStartsAt: TUtcDateTime;
begin
  Result := FStartsAt;
end;

function TAppointment.GetEndsAt: TUtcDateTime;
begin
  Result := FEndsAt;
end;

function TAppointment.GetStatus: string;
begin
  Result := FStatus;
end;

function TAppointment.GetVersion: Integer;
begin
  Result := FVersion;
end;

function TAppointmentFind.GetProfessional: IOptString;
begin
  Result := TOptionals.Safe(FProfessional);
end;

function TAppointmentFind.GetStatus: IOptString;
begin
  Result := TOptionals.Safe(FStatus);
end;

function TAppointmentFind.GetFrom: IOptString;
begin
  Result := TOptionals.Safe(FFrom);
end;

function TAppointmentFind.GetTo: IOptString;
begin
  Result := TOptionals.Safe(FTo);
end;

initialization
  TJsonMapper.Shared.RenameMember(TAppointmentFind, 'To_', 'to');
  TJsonMapper.Shared.RegisterMapping<IAppointmentInsert, TAppointmentInsert>;
  TJsonMapper.Shared.RegisterMapping<IAppointmentPatch, TAppointmentPatch>;
  TJsonMapper.Shared.RegisterMapping<IAppointment, TAppointment>;
  TJsonMapper.Shared.RegisterMapping<IAppointmentFind, TAppointmentFind>;
  TApiSchema.Describe(TypeInfo(IAppointmentInsert), 'A booking')
    .Prop('ProfessionalId').Desc('The professional''s id')
    .Prop('ServiceId').Desc('The service''s id')
    .Prop('CustomerId').Desc('The customer''s id')
    .Prop('StartsAt').Desc('A start GET /professionals/{id}/availability lists')
      .Format('date-time').Example('2026-11-02T12:00:00Z');
  TApiSchema.Describe(TypeInfo(IAppointmentPatch), 'The members to change; the others stay')
    .Prop('StartsAt').Desc('A new start: a free slot (its own time counted free), ISO 8601 ' +
      'with its zone').Format('date-time').Example('2026-11-02T13:00:00Z')
    .Prop('Status').Desc('confirmed, done or no_show (done and no_show once started); ' +
      'cancel through POST /appointments/{id}/cancel');
  TApiSchema.Describe(TypeInfo(IAppointment), 'An appointment')
    .Prop('StartsAt').Desc('UTC').Format('date-time')
    .Prop('EndsAt').Desc('UTC: the service''s end').Format('date-time')
    .Prop('Status').Desc('booked, confirmed, cancelled, done or no_show')
    .Prop('Version').Desc('Goes up with every change; the ETag is it in quotes, for If-Match');
  TApiSchema.Describe(TypeInfo(IAppointmentFind))
    .Prop('Page').Desc('Page number, from 1')
    .Prop('Limit').Desc('Entries per page (default 20, at most 100)')
    .Prop('OrderBy').Desc(AppointmentOrderSpec.DocHint)
    .Prop('Search').Desc('Not used here')
    .Prop('Professional').Desc('Only this professional''s')
    .Prop('Status').Desc('booked, confirmed, cancelled, done or no_show')
    .Prop('From').Desc('Only appointments that end after this instant (ISO 8601 with its zone)')
    .Prop('To_').Desc('Only appointments that start before this instant (ISO 8601 with its zone)');

end.
