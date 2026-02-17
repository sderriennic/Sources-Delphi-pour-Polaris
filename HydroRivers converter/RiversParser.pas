unit RiversParser;

{
  RiversParser.pas - Conversion HydroRIVERS (Shapefile polylines) en heightmap raster

  HydroRIVERS : 8,5 millions de tronçons de rivières (type Shapefile : PolyLine = type 3)

  Lecture des attributs via le composant TDBF (format dBASE III/IV, origine Borland).
  Le fichier .dbf accompagnant le .shp contient notamment :
    - ORD_STRA  : Ordre de Strahler (1 = ruisseau, 9 = grand fleuve)
    - DIS_AV_CMS: Débit moyen en m³/s

  Prérequis : composant TDBF disponible dans votre installation Delphi.
}

interface

uses
  System.SysUtils, System.Math, System.Types, System.Classes,
  Vcl.Graphics, Vcl.Imaging.PngImage,
  DBF,            // Composant TDBF
  DB,             // TField
  GeoConverter;

type
  TShapePoint = record
    X, Y: Double;
  end;

  TRiverPolyline = record
    Points   : array of TShapePoint;
    NumPoints: Integer;
    Order    : Integer;  // Ordre de Strahler (1-9)
    Discharge: Double;   // Débit moyen m³/s
  end;

  TRiversReader = class
  private
    FStream        : TFileStream;
    FDBF           : TDBF;
    FShapeType     : Integer;
    FHasDBF        : Boolean;
    FRecordIndex   : Integer;  // Synchronisation SHP / DBF

    // Champs DBF pré-résolus (évite FieldByName à chaque enregistrement)
    FFieldOrder    : TField;
    FFieldDischarge: TField;

    function ReadBigEndianInt32: Integer;
    function ReadLittleEndianInt32: Integer;
    function ReadDouble: Double;
    procedure ReadHeader;
    procedure OpenDBF(const ADBFPath: string);
  public
    constructor Create(const AShapefilePath: string);
    destructor Destroy; override;

    function ReadNextPolyline(out APolyline: TRiverPolyline): Boolean;
    procedure Reset;

    property ShapeType: Integer read FShapeType;
  end;

  TRiversRasterizer = class
  private
    FWidth  : Integer;
    FHeight : Integer;
    FBitmap : array of Byte;

    procedure DrawLine(X1, Y1, X2, Y2, AThickness: Integer);
    procedure DrawThickPoint(CX, CY, ARadius: Integer);
    procedure SetPixel(X, Y: Integer);
  public
    constructor Create(AWidth, AHeight: Integer);
    destructor Destroy; override;

    procedure Clear;
    procedure AddRiver(const APolyline: TRiverPolyline);

    class function OrderToRealWidth(AOrder: Integer): Integer;
    class function OrderToThickness(AOrder, AMapWidth: Integer): Integer;

    function  GetPixel(X, Y: Integer): Boolean;
    procedure SaveToFile(const AFileName: string);
    procedure SaveToBMP (const AFileName: string);
    procedure SaveToPNG (const AFileName: string);
  end;

implementation

{ ============================================================ }
{  TRiversReader                                               }
{ ============================================================ }

constructor TRiversReader.Create(const AShapefilePath: string);
var
  DBFPath: string;
begin
  inherited Create;
  FStream        := TFileStream.Create(AShapefilePath, fmOpenRead or fmShareDenyNone);
  FRecordIndex   := 0;
  FHasDBF        := False;
  FFieldOrder    := nil;
  FFieldDischarge:= nil;

  DBFPath := ChangeFileExt(AShapefilePath, '.dbf');
  if FileExists(DBFPath) then
    OpenDBF(DBFPath);

  ReadHeader;
end;

destructor TRiversReader.Destroy;
begin
  FStream.Free;
  if FHasDBF then
  begin
    FDBF.Close;
    FDBF.Free;
  end;
  inherited;
end;

procedure TRiversReader.OpenDBF(const ADBFPath: string);
begin
  FDBF := TDBF.Create(nil);
  try
    FDBF.FilePathFull := ADBFPath;
    FDBF.Open;
    FHasDBF := True;

    // Résoudre les champs une seule fois
    // (FieldByName à chaque enregistrement serait trop lent sur 8,5M records)
    FFieldOrder     := FDBF.FindField('ORD_STRA');
    FFieldDischarge := FDBF.FindField('DIS_AV_CMS');

    // ORD_STRA peut s'appeler ORD_FLOW selon la version HydroRIVERS
    if FFieldOrder = nil then
      FFieldOrder := FDBF.FindField('ORD_FLOW');

    if FFieldOrder = nil then
      WriteLn('ATTENTION : Champ ORD_STRA/ORD_FLOW non trouvé dans le DBF. ' +
              'Toutes les rivières seront tracées à 1 pixel.');

  except
    on E: Exception do
    begin
      FDBF.Free;
      FDBF    := nil;
      FHasDBF := False;
      WriteLn('ATTENTION : Impossible d''ouvrir le DBF : ', E.Message);
    end;
  end;
end;

function TRiversReader.ReadBigEndianInt32: Integer;
var
  B: array[0..3] of Byte;
begin
  FStream.Read(B, 4);
  Result := (B[0] shl 24) or (B[1] shl 16) or (B[2] shl 8) or B[3];
end;

function TRiversReader.ReadLittleEndianInt32: Integer;
begin
  FStream.Read(Result, 4);
end;

function TRiversReader.ReadDouble: Double;
begin
  FStream.Read(Result, 8);
end;

procedure TRiversReader.ReadHeader;
var
  I: Integer;
begin
  ReadBigEndianInt32;                  // File code (9994)
  for I := 1 to 5 do
    ReadBigEndianInt32;                // Unused
  ReadBigEndianInt32;                  // File length
  ReadLittleEndianInt32;               // Version
  FShapeType := ReadLittleEndianInt32; // Shape type (3 = PolyLine)
  for I := 0 to 7 do
    ReadDouble;                        // Bounding box + Z/M ranges
end;

function TRiversReader.ReadNextPolyline(out APolyline: TRiverPolyline): Boolean;
var
  ContentLength, ShapeType: Integer;
  NumParts, NumPoints, I  : Integer;
  Parts: array of Integer;
  Box  : array[0..3] of Double;
begin
  Result := False;
  APolyline.NumPoints := 0;
  APolyline.Order     := 1;
  APolyline.Discharge := 0;

  if FStream.Position >= FStream.Size then
    Exit;

  try
    ReadBigEndianInt32;               // Record number
    ContentLength := ReadBigEndianInt32;
    ShapeType     := ReadLittleEndianInt32;

    // Null shape : avancer le curseur DBF pour rester synchronisé
    if ShapeType = 0 then
    begin
      if FHasDBF and not FDBF.EOF then FDBF.Next;
      Inc(FRecordIndex);
      Exit;
    end;

    if ShapeType <> 3 then
    begin
      FStream.Seek((ContentLength * 2) - 4, soCurrent);
      if FHasDBF and not FDBF.EOF then FDBF.Next;
      Inc(FRecordIndex);
      Exit;
    end;

    // Bounding box
    for I := 0 to 3 do Box[I] := ReadDouble;

    NumParts  := ReadLittleEndianInt32;
    NumPoints := ReadLittleEndianInt32;

    SetLength(Parts, NumParts);
    for I := 0 to NumParts - 1 do
      Parts[I] := ReadLittleEndianInt32;

    SetLength(APolyline.Points, NumPoints);
    for I := 0 to NumPoints - 1 do
    begin
      APolyline.Points[I].X := ReadDouble;
      APolyline.Points[I].Y := ReadDouble;
    end;
    APolyline.NumPoints := NumPoints;

    // Lecture des attributs via TDBF
    // Le curseur DBF est synchronisé avec le SHP grâce aux FDBF.Next() ci-dessus
    if FHasDBF and not FDBF.EOF then
    begin
      if FFieldOrder <> nil then
        APolyline.Order := FFieldOrder.AsInteger;

      if FFieldDischarge <> nil then
        APolyline.Discharge := FFieldDischarge.AsFloat;

      FDBF.Next;
    end;

    Inc(FRecordIndex);
    Result := True;

  except
    Result := False;
  end;
end;

procedure TRiversReader.Reset;
begin
  FStream.Position := 100;  // Après l'en-tête SHP (100 octets)
  FRecordIndex     := 0;
  if FHasDBF then
    FDBF.First;             // Retour au premier enregistrement DBF
end;

{ ============================================================ }
{  TRiversRasterizer                                           }
{ ============================================================ }

constructor TRiversRasterizer.Create(AWidth, AHeight: Integer);
var
  BitmapSize: Int64;
begin
  inherited Create;
  FWidth     := AWidth;
  FHeight    := AHeight;
  BitmapSize := ((Int64(FWidth) * FHeight) + 7) div 8;
  SetLength(FBitmap, BitmapSize);
  Clear;
end;

destructor TRiversRasterizer.Destroy;
begin
  SetLength(FBitmap, 0);
  inherited;
end;

procedure TRiversRasterizer.Clear;
begin
  FillChar(FBitmap[0], Length(FBitmap), 0);
end;

function TRiversRasterizer.GetPixel(X, Y: Integer): Boolean;
var
  BitIndex : Int64;
  ByteIndex: Int64;
  BitMask  : Byte;
begin
  if (X < 0) or (X >= FWidth) or (Y < 0) or (Y >= FHeight) then
  begin
    Result := False;
    Exit;
  end;
  BitIndex  := Int64(Y) * FWidth + X;
  ByteIndex := BitIndex div 8;
  BitMask   := 1 shl (BitIndex mod 8);
  Result    := (FBitmap[ByteIndex] and BitMask) <> 0;
end;

procedure TRiversRasterizer.SetPixel(X, Y: Integer);
var
  BitIndex : Int64;
  ByteIndex: Int64;
  BitMask  : Byte;
begin
  if (X < 0) or (X >= FWidth) or (Y < 0) or (Y >= FHeight) then
    Exit;
  BitIndex  := Int64(Y) * FWidth + X;
  ByteIndex := BitIndex div 8;
  BitMask   := 1 shl (BitIndex mod 8);
  FBitmap[ByteIndex] := FBitmap[ByteIndex] or BitMask;
end;

procedure TRiversRasterizer.DrawThickPoint(CX, CY, ARadius: Integer);
var
  DX, DY: Integer;
begin
  if ARadius <= 0 then
  begin
    SetPixel(CX, CY);
    Exit;
  end;
  for DY := -ARadius to ARadius do
    for DX := -ARadius to ARadius do
      if (DX * DX + DY * DY) <= (ARadius * ARadius) then
        SetPixel(CX + DX, CY + DY);
end;

procedure TRiversRasterizer.DrawLine(X1, Y1, X2, Y2, AThickness: Integer);
var
  DX, DY, SX, SY, Err, E2: Integer;
  Radius: Integer;
begin
  Radius := AThickness div 2;
  DX     := Abs(X2 - X1);
  DY     := Abs(Y2 - Y1);
  SX     := IfThen(X1 < X2, 1, -1);
  SY     := IfThen(Y1 < Y2, 1, -1);
  Err    := DX - DY;

  while True do
  begin
    DrawThickPoint(X1, Y1, Radius);
    if (X1 = X2) and (Y1 = Y2) then Break;
    E2 := 2 * Err;
    if E2 > -DY then begin Err := Err - DY; X1 := X1 + SX; end;
    if E2 <  DX then begin Err := Err + DX; Y1 := Y1 + SY; end;
  end;
end;

{
  Largeur réelle approximative par ordre de Strahler (en mètres) :
    Ordre 1 :     5 m  (ruisseau)
    Ordre 2 :    15 m
    Ordre 3 :    40 m
    Ordre 4 :   100 m
    Ordre 5 :   250 m  (rivière)
    Ordre 6 :   600 m
    Ordre 7 :  1500 m
    Ordre 8 :  4000 m  (grand fleuve)
    Ordre 9 : 10000 m  (Amazone, Congo...)

  La carte couvre 360° de longitude = 40 075 000 m à l'équateur.
  Résolution en m/pixel = 40 075 000 / FWidth
  Épaisseur en pixels   = LargeurRéelle / MètresParPixel
  Si épaisseur < 1 pixel → rivière ignorée (trop petite pour la résolution)
}

// Largeur réelle en mètres par ordre de Strahler
class function TRiversRasterizer.OrderToRealWidth(AOrder: Integer): Integer;
begin
  case AOrder of
    1   : Result :=    5;
    2   : Result :=   15;
    3   : Result :=   40;
    4   : Result :=  100;
    5   : Result :=  250;
    6   : Result :=  600;
    7   : Result := 1500;
    8   : Result := 4000;
    9   : Result := 10000;
  else
    Result := 5;
  end;
end;

// Calcule l'épaisseur en pixels pour une résolution donnée.
// Retourne 0 si la rivière est trop petite pour être visible.
class function TRiversRasterizer.OrderToThickness(AOrder, AMapWidth: Integer): Integer;
const
  EARTH_CIRCUMFERENCE = 40075000.0;  // mètres à l'équateur
var
  MetersPerPixel: Double;
  RealWidth     : Integer;
  PixelWidth    : Double;
begin
  MetersPerPixel := EARTH_CIRCUMFERENCE / AMapWidth;
  RealWidth      := OrderToRealWidth(AOrder);
  PixelWidth     := RealWidth / MetersPerPixel;

  if PixelWidth < 1.0 then
    Result := 0   // Trop petite : ignorer
  else
    Result := Max(1, Round(PixelWidth));
end;

procedure TRiversRasterizer.AddRiver(const APolyline: TRiverPolyline);
var
  I        : Integer;
  P1, P2   : TPixelPoint;
  G1, G2   : TGeoPoint;
  Thickness: Integer;
begin
  if APolyline.NumPoints < 2 then Exit;

  // Calcul de l'épaisseur proportionnelle à la résolution de la carte
  Thickness := OrderToThickness(APolyline.Order, FWidth);

  // Rivière trop petite pour la résolution courante → ignorer
  if Thickness = 0 then Exit;

  for I := 0 to APolyline.NumPoints - 2 do
  begin
    G1.Longitude := APolyline.Points[I].X;
    G1.Latitude  := APolyline.Points[I].Y;
    G2.Longitude := APolyline.Points[I + 1].X;
    G2.Latitude  := APolyline.Points[I + 1].Y;
    P1 := TGeoConverter.GeoToPixel(G1, FWidth, FHeight);
    P2 := TGeoConverter.GeoToPixel(G2, FWidth, FHeight);
    DrawLine(P1.X, P1.Y, P2.X, P2.Y, Thickness);
  end;
end;

procedure TRiversRasterizer.SaveToFile(const AFileName: string);
var
  Stream: TFileStream;
  X, Y  : Integer;
  Value : Byte;
begin
  Stream := TFileStream.Create(AFileName, fmCreate);
  try
    for Y := 0 to FHeight - 1 do
      for X := 0 to FWidth - 1 do
      begin
        Value := IfThen(GetPixel(X, Y), 255, 0);
        Stream.Write(Value, 1);
      end;
  finally
    Stream.Free;
  end;
end;

procedure TRiversRasterizer.SaveToBMP(const AFileName: string);
var
  Bitmap  : TBitmap;
  Y, X    : Integer;
  ScanLine: PByteArray;
begin
  Bitmap := TBitmap.Create;
  try
    Bitmap.PixelFormat := pf24bit;
    Bitmap.Width       := FWidth;
    Bitmap.Height      := FHeight;
    for Y := 0 to FHeight - 1 do
    begin
      ScanLine := Bitmap.ScanLine[Y];
      for X := 0 to FWidth - 1 do
      begin
        if GetPixel(X, Y) then
        begin
          ScanLine[X * 3 + 0] := 255;  // B
          ScanLine[X * 3 + 1] := 150;  // G
          ScanLine[X * 3 + 2] := 50;   // R
        end
        else
        begin
          ScanLine[X * 3 + 0] := 160;
          ScanLine[X * 3 + 1] := 200;
          ScanLine[X * 3 + 2] := 220;
        end;
      end;
    end;
    Bitmap.SaveToFile(AFileName);
  finally
    Bitmap.Free;
  end;
end;

procedure TRiversRasterizer.SaveToPNG(const AFileName: string);
var
  PNG          : TPngImage;
  Y, X         : Integer;
  ScanLine     : PByteArray;
  AlphaScanLine: PByteArray;
begin
  PNG := TPngImage.Create;
  try
    PNG.CreateBlank(COLOR_RGBALPHA, 8, FWidth, FHeight);
    for Y := 0 to FHeight - 1 do
    begin
      ScanLine      := PNG.ScanLine[Y];
      AlphaScanLine := PNG.AlphaScanLine[Y];
      for X := 0 to FWidth - 1 do
      begin
        if GetPixel(X, Y) then
        begin
          ScanLine[X * 3 + 0] := 255;
          ScanLine[X * 3 + 1] := 150;
          ScanLine[X * 3 + 2] := 50;
          AlphaScanLine[X]    := 255;
        end
        else
        begin
          ScanLine[X * 3 + 0] := 0;
          ScanLine[X * 3 + 1] := 0;
          ScanLine[X * 3 + 2] := 0;
          AlphaScanLine[X]    := 0;
        end;
      end;
    end;
    PNG.SaveToFile(AFileName);
  finally
    PNG.Free;
  end;
end;

end.
