unit Agenda.Events;

{$I agenda.inc}

{ The application's events, as they go through the outbox (Agenda.Outbox).

  Thin (M4 decision 2): the appointment's id and the version the change
  wrote, nothing personal. Whoever handles one reads the appointment as it
  is now; a version above the event's means a later change, with its own
  event, came after it. The tenant is the outbox row's.

  Kinds (M4 decision 7): booked, moved, cancelled (by staff or by link), and
  reminder (queued by the worker's scheduler). A status change to confirmed,
  done or no_show has none. }

interface

const
  EVENT_APPOINTMENT_BOOKED = 'appointment.booked';
  EVENT_APPOINTMENT_MOVED = 'appointment.moved';
  EVENT_APPOINTMENT_CANCELLED = 'appointment.cancelled';
  EVENT_APPOINTMENT_REMINDER = 'appointment.reminder';

type
  IAppointmentEvent = interface
    ['{7A1E5C93-2B4D-4F86-9C0A-E3D5B7F12A48}']
    function GetAppointmentId: string;
    function GetVersion: Integer;
    property AppointmentId: string read GetAppointmentId;
    property Version: Integer read GetVersion;
  end;

{$M+}
  TAppointmentEvent = class(TInterfacedObject, IAppointmentEvent)
  private
    FAppointmentId: string;
    FVersion: Integer;
  public
    function GetAppointmentId: string;
    function GetVersion: Integer;
  published
    property AppointmentId: string read FAppointmentId write FAppointmentId;
    property Version: Integer read FVersion write FVersion;
  end;
{$M-}

/// {"appointmentId":"...","version":N}
function AppointmentEventPayload(const AAppointmentId: string; AVersion: Integer): string;
/// The payload back; the mapper's exception for text that isn't one.
function ReadAppointmentEvent(const APayload: string): IAppointmentEvent;

implementation

uses
  PascalJsonMapper.Mapper;

function TAppointmentEvent.GetAppointmentId: string;
begin
  Result := FAppointmentId;
end;

function TAppointmentEvent.GetVersion: Integer;
begin
  Result := FVersion;
end;

function AppointmentEventPayload(const AAppointmentId: string; AVersion: Integer): string;
var
  LEvent: TAppointmentEvent;
  LIntf: IAppointmentEvent;
begin
  LEvent := TAppointmentEvent.Create;
  LIntf := LEvent;
  LEvent.AppointmentId := AAppointmentId;
  LEvent.Version := AVersion;
  Result := TJsonMapper.Shared.ToJson<IAppointmentEvent>(LIntf);
end;

function ReadAppointmentEvent(const APayload: string): IAppointmentEvent;
begin
  Result := TJsonMapper.Shared.FromJson<IAppointmentEvent>(APayload);
end;

initialization
  TJsonMapper.Shared.RegisterMapping<IAppointmentEvent, TAppointmentEvent>;

end.
