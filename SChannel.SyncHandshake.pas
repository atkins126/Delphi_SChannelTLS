{
  Helper function that implements synchronous TLS handshake by means of
  Windows SChannel.
  The function is transport-agnostic so it could be applied to any socket
  implementation or even other transport.

  Inspired by TLS-Sample from http://www.coastrd.com/c-schannel-smtp

  Uses JEDI API units from https://jedi-apilib.sourceforge.net

  (c) Fr0sT-Brutal
  License MIT
}

unit SChannel.SyncHandshake;

interface
{$IFDEF MSWINDOWS}

uses
  Windows, SysUtils,
  JwaBaseTypes, JwaWinError, JwaWinCrypt, JwaSspi, JwaSChannel,
  SChannel.Utils;

type
  // Logging function. All messages coming from functions of this unit are
  // prefixed with `SChannel.Utils.LogPrefix` constant
  TLogFn = procedure (const Msg: string) of object;
  // Synchronous communication function.
  //   @param Data - the value of `Data` with which `PerformClientHandshake` was called \
  //     (Socket object, handle, etc)
  //   @param Buf - buffer with data
  //   @param BufLen - size of data in buffer
  // @returns amount of data sent. Must try to send all data in full, as no \
  //   retries or repeated sends is done.
  // @raises exception on error
  TSendFn = function (Data: Pointer; Buf: Pointer; BufLen: Integer): Integer;
  // Synchronous communication function.
  //   @param Data - the value of `Data` with which `PerformClientHandshake` was called \
  //     (Socket object, handle, etc)
  //   @param Buf - buffer to receive data
  //   @param BufLen - size of free space in buffer
  // @returns amount of data read, `0` if no data read and `-1` on error.\
  //   Must try to send all data in full, as no retries or repeated sends is done.
  // @raises exception on error
  TRecvFn = function (Data: Pointer; Buf: Pointer; BufLen: Integer): Integer;

// Synchronously perform full handshake process including communication with server.
procedure PerformClientHandshake(const SessionData: TSessionData; const ServerName: string;
  LogFn: TLogFn; Data: Pointer; SendFn: TSendFn; RecvFn: TRecvFn;
  out hContext: CtxtHandle);

{$ENDIF MSWINDOWS}

implementation
{$IFDEF MSWINDOWS}

// ~~ Utils ~~

// Empty default logging function - to avoid if Assigned checks
type
  TLogFnHoster = class
    class procedure DefLogFn(const Msg: string);
  end;

class procedure TLogFnHoster.DefLogFn(const Msg: string);
begin
end;

// Synchronously perform full handshake process including communication with server.
// Communication is done via two callback functions.
//   @param SessionData - record with session data
//   @param ServerName - name of domain to connect to
//   @param Data - any data with which `SendFn` and `RecvFn` will be called
//   @param hContext - [OUT] receives current session context
// @raises ESSPIError on error
procedure PerformClientHandshake(const SessionData: TSessionData; const ServerName: string;
  LogFn: TLogFn; Data: Pointer; SendFn: TSendFn; RecvFn: TRecvFn;
  out hContext: CtxtHandle);
var
  HandShakeData: THandShakeData;
  cbData: Integer;
begin
  HandShakeData := Default(THandShakeData);
  HandShakeData.ServerName := ServerName;
  hContext := Default(CtxtHandle);
  if not Assigned(LogFn) then
    LogFn := TLogFnHoster.DefLogFn;

  try try
    // Generate hello
    DoClientHandshake(SessionData, HandShakeData);
    Assert(HandShakeData.Stage = hssSendCliHello);

    // Send hello to server
    cbData := SendFn(Data, HandShakeData.OutBuffers[0].pvBuffer, HandShakeData.OutBuffers[0].cbBuffer);
    if cbData = HandShakeData.OutBuffers[0].cbBuffer then
      LogFn(LogPrefix + Format('Handshake - %d bytes sent', [cbData]))
    else
      LogFn(LogPrefix + 'Handshake - ! data sent partially');
    g_pSSPI.FreeContextBuffer(HandShakeData.OutBuffers[0].pvBuffer); // Free output buffer.
    SetLength(HandShakeData.OutBuffers, 0);
    HandShakeData.Stage := hssReadSrvHello;

    // Read hello from server
    SetLength(HandShakeData.IoBuffer, IO_BUFFER_SIZE);
    HandShakeData.cbIoBuffer := 0;
    // Read response until it is complete
    repeat
      if HandShakeData.Stage = hssReadSrvHello then
      begin
        cbData := RecvFn(Data, (PByte(HandShakeData.IoBuffer) + HandShakeData.cbIoBuffer),
          Length(HandShakeData.IoBuffer) - HandShakeData.cbIoBuffer);
        if cbData <= 0 then // should not happen
          raise ESSPIError.Create('Handshake - no data received or error receiving');
        LogFn(LogPrefix + Format('Handshake - %d bytes received', [cbData]));
        Inc(HandShakeData.cbIoBuffer, cbData);
      end;

      // Decode hello
      DoClientHandshake(SessionData, HandShakeData);

      // Send token if needed
      if HandShakeData.Stage in [hssReadSrvHelloContNeed, hssReadSrvHelloOK] then
      begin
        if (HandShakeData.OutBuffers[0].cbBuffer > 0) and (HandShakeData.OutBuffers[0].pvBuffer <> nil) then
        begin
          cbData := SendFn(Data, HandShakeData.OutBuffers[0].pvBuffer, HandShakeData.OutBuffers[0].cbBuffer);
          if cbData = HandShakeData.OutBuffers[0].cbBuffer then
            LogFn(LogPrefix + Format('Handshake - %d bytes sent', [cbData]))
          else
            LogFn(LogPrefix + 'Handshake - ! data sent partially');
          g_pSSPI.FreeContextBuffer(HandShakeData.OutBuffers[0].pvBuffer); // Free output buffer
          SetLength(HandShakeData.OutBuffers, 0);
        end;

        if HandShakeData.Stage = hssReadSrvHelloContNeed then
        begin
          HandShakeData.Stage := hssReadSrvHello;
          Continue;
        end
        else if HandShakeData.Stage = hssReadSrvHelloOK then
        begin
          LogFn(LogPrefix + 'Handshake - success');
          HandShakeData.Stage := hssDone;
          Break;
        end;
      end;

    until False;
  except
    begin
      // Delete the security context in the case of a fatal error.
      DeleteContext(HandShakeData.hContext);
      raise;
    end;
  end;
  finally
    begin
      if Length(HandShakeData.OutBuffers) > 0 then
        g_pSSPI.FreeContextBuffer(HandShakeData.OutBuffers[0].pvBuffer); // Free output buffer
      hContext := HandShakeData.hContext;
    end;
  end;
end;

{$ENDIF MSWINDOWS}
end.
