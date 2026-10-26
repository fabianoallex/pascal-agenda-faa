unit Agenda.Mail;

{$I agenda.inc}

{ Email out of the worker (docs/design.md, M4 decision 4): an application
  interface, IMailSender, with two implementations that share one message
  text (MailToMime):

  - TSmtpMailSender: SMTP through Synapse's TSMTPSend, plain, STARTTLS or
    TLS from the first byte (OpenSSL 3, ssl_openssl3), with or without a
    login. One connection per message: the worker sends few.
  - TEmlMailSender: each message as an .eml file in a directory (unit tests,
    a run without a mail server). Written to a temporary name and renamed,
    so a reader never sees half a file.

  The message is one text/plain part in UTF-8, written here: the subject
  and a display name as RFC 2047 encoded words, the body as quoted-printable
  of its UTF-8 bytes (RFC 2045: lines of 76 at most), long headers folded at
  a space. Synapse's MIME classes (TMimeMess) were the first try and were
  dropped: on Delphi their text goes through the ANSI code page; they encode
  again any header with "=", "?", ":" or "," (an encoded word included, and
  an ASCII subject came out as ISO-8859-1 Q-encoding); they always write an
  empty "From:" of their own; and their quoted-printable wrote lines of 79.
  Synapse stays for SMTP (and its RFC 822 date).

  Not library material (decided 2026-10-18): the application's. }

interface

uses
  SysUtils;

type
  EMailError = class(Exception);

  TMailMessage = record
    /// "address" or "Display name <address>".
    From: string;
    /// One address.
    ToAddress: string;
    Subject: string;
    /// Plain text; lines end in #10 or #13#10.
    TextBody: string;
    /// Without the angle brackets; '' for none.
    MessageId: string;
    /// Extra header lines, "Name: value", ASCII only.
    Headers: TArray<string>;
  end;

  IMailSender = interface
    ['{2F7D4A90-6B1C-4E35-A8D2-C94E0B13F657}']
    /// Raises EMailError (or Synapse's socket error) when the message wasn't
    /// accepted.
    procedure Send(const AMessage: TMailMessage);
  end;

  TSmtpSecurity = (smPlain, smStartTls, smTls);

  TSmtpOptions = record
    Host: string;
    Port: Integer;
    /// '' for no login.
    User: string;
    Password: string;
    Security: TSmtpSecurity;
    TimeoutMs: Integer;
    /// localhost, 25, no login, plain, 30 s.
    class function Default: TSmtpOptions; static;
  end;

  TSmtpMailSender = class(TInterfacedObject, IMailSender)
  private
    FOptions: TSmtpOptions;
  public
    constructor Create(const AOptions: TSmtpOptions);
    procedure Send(const AMessage: TMailMessage);
  end;

  TEmlMailSender = class(TInterfacedObject, IMailSender)
  private
    FDirectory: string;
  public
    /// ADirectory is created when missing.
    constructor Create(const ADirectory: string);
    procedure Send(const AMessage: TMailMessage);
    property Directory: string read FDirectory;
  end;

/// The message as it goes on the wire (lines ending in #13#10, ASCII only).
/// EMailError for a message with no sender, recipient or subject.
function MailToMime(const AMessage: TMailMessage; ADate: TDateTime): string;

/// "Display name <address>" or "address": the address.
function MailAddress(const AText: string): string;

/// AText as RFC 2047 encoded words (UTF-8, Base64, separated by a space)
/// when it has a character outside printable ASCII; as it is otherwise.
function MailEncodeWords(const AText: string): string;

implementation

uses
  Classes,
  PascalCommon.Crypto,
  PascalCommon.Random,
  synautil,
  smtpsend,
  ssl_openssl3;

const
  CRLF = #13#10;
  // An encoded word's text: 39 bytes of UTF-8 are 52 Base64 characters, a
  // word of 64 with "=?UTF-8?B?" and "?=" (RFC 2047: 75 at most), so
  // "Subject: " and one word fit in a line of 76.
  WORD_BYTES = 39;
  // Quoted-printable: 76 characters a line, the soft break's "=" included;
  // the headers are folded to the same width.
  LINE_WIDTH = 76;
  HEX_DIGITS: array[0..15] of Char = ('0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
    'A', 'B', 'C', 'D', 'E', 'F');

function IsPlainAscii(const AText: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(AText) do
    if (Ord(AText[I]) < 32) or (Ord(AText[I]) > 126) then
      Exit(False);
  Result := True;
end;

// Standard Base64 with padding, from pascal-common-faa's Base64url.
function Base64(const ABytes: TBytes): string;
var
  I: Integer;
begin
  Result := PcBase64UrlEncode(ABytes);
  for I := 1 to Length(Result) do
    if Result[I] = '-' then
      Result[I] := '+'
    else if Result[I] = '_' then
      Result[I] := '/';
  while Length(Result) mod 4 <> 0 do
    Result := Result + '=';
end;

function MailEncodeWords(const AText: string): string;
var
  LBytes, LChunk: TBytes;
  LStart, LEnd: Integer;
begin
  if IsPlainAscii(AText) then
    Exit(AText);
  LBytes := TEncoding.UTF8.GetBytes(UnicodeString(AText));
  Result := '';
  LStart := 0;
  while LStart < Length(LBytes) do
  begin
    LEnd := LStart + WORD_BYTES;
    if LEnd >= Length(LBytes) then
      LEnd := Length(LBytes)
    else
      // Never split a character: back off a continuation byte (10xxxxxx).
      while (LEnd > LStart + 1) and ((LBytes[LEnd] and $C0) = $80) do
        Dec(LEnd);
    LChunk := Copy(LBytes, LStart, LEnd - LStart);
    // A space between words: a reader drops it, a fold may go there.
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + '=?UTF-8?B?' + Base64(LChunk) + '?=';
    LStart := LEnd;
  end;
end;

// "Name: value" and its line break, folded at spaces so no line passes
// LINE_WIDTH where a space allows it (RFC 5322 asks for 78).
function FoldHeader(const AName, AValue: string): string;
var
  LLine, LWord, LRest: string;
  LSpace: Integer;
begin
  Result := '';
  LLine := AName + ':';
  LRest := AValue;
  while LRest <> '' do
  begin
    LSpace := Pos(' ', LRest);
    if LSpace = 0 then
    begin
      LWord := LRest;
      LRest := '';
    end
    else
    begin
      LWord := Copy(LRest, 1, LSpace - 1);
      LRest := Copy(LRest, LSpace + 1, MaxInt);
    end;
    if (Length(LLine) + 1 + Length(LWord) > LINE_WIDTH) and (LLine <> AName + ':') then
    begin
      Result := Result + LLine + CRLF;
      LLine := '';
    end;
    LLine := LLine + ' ' + LWord;
  end;
  Result := Result + LLine + CRLF;
end;

// One line of text (no line break in it, as UTF-8 bytes) as quoted-printable
// lines, soft breaks ("=" at the end) where it passes LINE_WIDTH.
function QuotedPrintableLine(const ABytes: TBytes): string;
var
  LLine, LToken: string;
  I: Integer;
  B: Byte;
begin
  Result := '';
  LLine := '';
  for I := 0 to High(ABytes) do
  begin
    B := ABytes[I];
    // A space or a tab at the end of a line would be dropped: encoded there.
    if ((B >= 33) and (B <= 126) and (B <> Ord('='))) or
      (((B = 32) or (B = 9)) and (I < High(ABytes))) then
      LToken := Char(B)
    else
      LToken := '=' + HEX_DIGITS[B shr 4] + HEX_DIGITS[B and 15];
    if Length(LLine) + Length(LToken) > LINE_WIDTH - 1 then
    begin
      Result := Result + LLine + '=' + CRLF;
      LLine := '';
    end;
    LLine := LLine + LToken;
  end;
  Result := Result + LLine + CRLF;
end;

function QuotedPrintable(const AText: string): string;
var
  LText, LLine: string;
  LBreak: Integer;
begin
  Result := '';
  LText := StringReplace(AText, CRLF, #10, [rfReplaceAll]);
  while LText <> '' do
  begin
    LBreak := Pos(#10, LText);
    if LBreak = 0 then
      LBreak := Length(LText) + 1;
    LLine := Copy(LText, 1, LBreak - 1);
    Delete(LText, 1, LBreak);
    Result := Result + QuotedPrintableLine(TEncoding.UTF8.GetBytes(UnicodeString(LLine)));
  end;
end;

function MailAddress(const AText: string): string;
var
  LOpen, LClose: Integer;
begin
  LOpen := LastDelimiter('<', AText);
  LClose := LastDelimiter('>', AText);
  if (LOpen > 0) and (LClose > LOpen) then
    Result := Trim(Copy(AText, LOpen + 1, LClose - LOpen - 1))
  else
    Result := Trim(AText);
end;

// "Name <address>" with the name quoted, or encoded when it needs to be.
function EncodeMailbox(const AText: string): string;
var
  LName: string;
  LOpen: Integer;
begin
  LOpen := LastDelimiter('<', AText);
  if LOpen <= 1 then
    Exit(MailAddress(AText));
  LName := Trim(Copy(AText, 1, LOpen - 1));
  if LName = '' then
    Exit(MailAddress(AText));
  if IsPlainAscii(LName) then
    LName := '"' + StringReplace(LName, '"', '''', [rfReplaceAll]) + '"'
  else
    LName := MailEncodeWords(LName);
  Result := LName + ' <' + MailAddress(AText) + '>';
end;

function MailToMime(const AMessage: TMailMessage; ADate: TDateTime): string;
var
  I: Integer;
begin
  if (MailAddress(AMessage.From) = '') or (MailAddress(AMessage.ToAddress) = '') or
    (AMessage.Subject = '') then
    raise EMailError.Create('A message needs a sender, a recipient and a subject.');
  Result := FoldHeader('From', EncodeMailbox(AMessage.From)) +
    'To: ' + MailAddress(AMessage.ToAddress) + CRLF +
    FoldHeader('Subject', MailEncodeWords(AMessage.Subject)) +
    'Date: ' + Rfc822DateTime(ADate) + CRLF;
  if AMessage.MessageId <> '' then
    Result := Result + 'Message-ID: <' + AMessage.MessageId + '>' + CRLF;
  for I := 0 to High(AMessage.Headers) do
    Result := Result + AMessage.Headers[I] + CRLF;
  Result := Result +
    'MIME-Version: 1.0' + CRLF +
    'Content-Type: text/plain; charset=UTF-8' + CRLF +
    'Content-Transfer-Encoding: quoted-printable' + CRLF +
    CRLF +
    QuotedPrintable(AMessage.TextBody);
end;

{ TSmtpOptions }

class function TSmtpOptions.Default: TSmtpOptions;
begin
  Result.Host := 'localhost';
  Result.Port := 25;
  Result.User := '';
  Result.Password := '';
  Result.Security := smPlain;
  Result.TimeoutMs := 30000;
end;

{ TSmtpMailSender }

constructor TSmtpMailSender.Create(const AOptions: TSmtpOptions);
begin
  inherited Create;
  FOptions := AOptions;
end;

procedure TSmtpMailSender.Send(const AMessage: TMailMessage);
var
  LSmtp: TSMTPSend;
  LLines: TStringList;

  procedure Check(AOk: Boolean; const AStep: string);
  begin
    if not AOk then
      raise EMailError.CreateFmt('SMTP %s:%d, %s: %d %s', [FOptions.Host, FOptions.Port,
        AStep, LSmtp.ResultCode, Trim(LSmtp.ResultString)]);
  end;

begin
  LLines := TStringList.Create;
  LSmtp := TSMTPSend.Create;
  try
    // ASCII only (MailToMime), so TStrings' code page doesn't matter here.
    LLines.Text := MailToMime(AMessage, Now);
    LSmtp.TargetHost := FOptions.Host;
    LSmtp.TargetPort := IntToStr(FOptions.Port);
    LSmtp.Timeout := FOptions.TimeoutMs;
    LSmtp.UserName := FOptions.User;
    LSmtp.Password := FOptions.Password;
    LSmtp.AutoTLS := FOptions.Security = smStartTls;
    LSmtp.FullSSL := FOptions.Security = smTls;
    Check(LSmtp.Login, 'login');
    try
      if (FOptions.Security = smStartTls) and not LSmtp.Sock.SSL.SSLEnabled then
        raise EMailError.CreateFmt('SMTP %s:%d offers no STARTTLS.',
          [FOptions.Host, FOptions.Port]);
      Check(LSmtp.MailFrom(MailAddress(AMessage.From), Length(LLines.Text)), 'MAIL FROM');
      Check(LSmtp.MailTo(MailAddress(AMessage.ToAddress)), 'RCPT TO');
      // MailData doubles a leading "." (SMTP's dot-stuffing).
      Check(LSmtp.MailData(LLines), 'DATA');
    finally
      LSmtp.Logout;
    end;
  finally
    LSmtp.Free;
    LLines.Free;
  end;
end;

{ TEmlMailSender }

constructor TEmlMailSender.Create(const ADirectory: string);
begin
  inherited Create;
  FDirectory := IncludeTrailingPathDelimiter(ExpandFileName(ADirectory));
  // Two processes starting at once: ForceDirectories fails for the one whose
  // CreateDir lost the race (seen with two workers on FPC/Linux), though the
  // directory is there.
  if not ForceDirectories(FDirectory) and not DirectoryExists(FDirectory) then
    raise EMailError.CreateFmt('Can''t create the directory %s.', [FDirectory]);
end;

procedure TEmlMailSender.Send(const AMessage: TMailMessage);
var
  LName, LTemp: string;
  LBytes: TBytes;
  LStream: TFileStream;
begin
  LBytes := TEncoding.ASCII.GetBytes(UnicodeString(MailToMime(AMessage, Now)));
  // A sortable name: the time, then random hex (two messages in one second).
  LName := FDirectory + FormatDateTime('yyyymmdd"-"hhnnsszzz', Now) + '-' +
    PcBytesToHex(PcRandomBytes(4)) + '.eml';
  LTemp := LName + '.tmp';
  LStream := TFileStream.Create(LTemp, fmCreate);
  try
    if Length(LBytes) > 0 then
      LStream.WriteBuffer(LBytes[0], Length(LBytes));
  finally
    LStream.Free;
  end;
  if not RenameFile(LTemp, LName) then
    raise EMailError.CreateFmt('Can''t rename %s.', [LTemp]);
end;

end.
