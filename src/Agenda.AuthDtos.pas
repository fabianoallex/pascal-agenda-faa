unit Agenda.AuthDtos;

{$I agenda.inc}

(* The bodies of the authentication routes: what pascal-jsonmapper-faa reads
  and writes (published properties under M+, the libraries' DTO convention)
  and what the OpenAPI document describes (TApiSchema.Describe below). JSON
  names are the properties' in camelCase: accessToken, refreshToken. *)

interface

uses
  PascalApi.Dto;

type
  ILoginRequest = interface(IInsertDTOBase)
    ['{07A189D0-87D2-49BC-92A9-3DCC839D0266}']
    function GetTenant: string;
    function GetEmail: string;
    function GetPassword: string;
  end;

  IRefreshRequest = interface(IInsertDTOBase)
    ['{35A5146D-690E-4564-ADC9-A6E864D58268}']
    function GetRefreshToken: string;
  end;

  ITokensResponse = interface(IResponseDTOBase)
    ['{1D4DFF5C-B2DA-43E4-BD57-BC0878D37B2E}']
  end;

  IMeResponse = interface(IResponseDTOBase)
    ['{92703576-D254-4FA5-9BD8-8AC6489ED73E}']
  end;

{$M+}
  TLoginRequest = class(TInsertDTOBase, ILoginRequest)
  private
    FTenant, FEmail, FPassword: string;
  public
    function GetTenant: string;
    function GetEmail: string;
    function GetPassword: string;
  published
    property Tenant: string read FTenant write FTenant;
    property Email: string read FEmail write FEmail;
    property Password: string read FPassword write FPassword;
  end;

  TRefreshRequest = class(TInsertDTOBase, IRefreshRequest)
  private
    FRefreshToken: string;
  public
    function GetRefreshToken: string;
  published
    property RefreshToken: string read FRefreshToken write FRefreshToken;
  end;

  TTokensResponse = class(TResponseDTOBase, ITokensResponse)
  private
    FAccessToken, FTokenType, FRefreshToken: string;
    FExpiresIn: Int64;
  published
    property AccessToken: string read FAccessToken write FAccessToken;
    property TokenType: string read FTokenType write FTokenType;
    property ExpiresIn: Int64 read FExpiresIn write FExpiresIn;
    property RefreshToken: string read FRefreshToken write FRefreshToken;
  end;

  TMeResponse = class(TResponseDTOBase, IMeResponse)
  private
    FId, FEmail, FRole, FTenant: string;
  published
    property Id: string read FId write FId;
    property Email: string read FEmail write FEmail;
    property Role: string read FRole write FRole;
    property Tenant: string read FTenant write FTenant;
  end;
{$M-}

implementation

uses
  PascalJsonMapper.Mapper,
  PascalApi.OpenApi;

function TLoginRequest.GetTenant: string;
begin
  Result := FTenant;
end;

function TLoginRequest.GetEmail: string;
begin
  Result := FEmail;
end;

function TLoginRequest.GetPassword: string;
begin
  Result := FPassword;
end;

function TRefreshRequest.GetRefreshToken: string;
begin
  Result := FRefreshToken;
end;

initialization
  TJsonMapper.Shared.RegisterMapping<ILoginRequest, TLoginRequest>;
  TJsonMapper.Shared.RegisterMapping<IRefreshRequest, TRefreshRequest>;
  TJsonMapper.Shared.RegisterMapping<ITokensResponse, TTokensResponse>;
  TJsonMapper.Shared.RegisterMapping<IMeResponse, TMeResponse>;
  TApiSchema.Describe(TypeInfo(ILoginRequest), 'Credentials of a user of one tenant')
    .Prop('Tenant').Desc('The tenant''s id (its slug)').Example('demo')
    .Prop('Email').Desc('The user''s email').Example('owner@demo.test')
    .Prop('Password').Desc('The user''s password').Example('a long passphrase');
  TApiSchema.Describe(TypeInfo(IRefreshRequest), 'A refresh token')
    .Prop('RefreshToken').Desc('As returned by the login or the last refresh; used once');
  TApiSchema.Describe(TypeInfo(ITokensResponse), 'An access token and the next refresh token')
    .Prop('AccessToken').Desc('JWT for Authorization: Bearer')
    .Prop('TokenType').Desc('Always Bearer').Example('Bearer')
    .Prop('ExpiresIn').Desc('Seconds until the access token expires').Example('900')
    .Prop('RefreshToken').Desc('Exchanges for new tokens once, at /auth/refresh');
  TApiSchema.Describe(TypeInfo(IMeResponse), 'The caller')
    .Prop('Id').Desc('The user''s id')
    .Prop('Role').Desc('owner or staff').Example('owner')
    .Prop('Tenant').Desc('The tenant''s id').Example('demo');

end.
