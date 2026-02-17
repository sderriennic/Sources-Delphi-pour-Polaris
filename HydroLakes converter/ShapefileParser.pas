unit ShapefileParser;

interface

uses
  System.SysUtils, System.Math, System.Types, System.Classes,
  Vcl.Graphics, GeoConverter;

type
  TShapePoint = record
    X, Y: Double;
  end;

  TShapeRing = array of TShapePoint;
  
  TShapePolygon = record
    Rings: array of TShapeRing;
    NumRings: Integer;
  end;

  TShapefileReader = class
  private
    FStream: TFileStream;
    FShapeType: Integer;
    FBoundingBox: array[0..3] of Double;
    
    function ReadBigEndianInt32: Integer;
    function ReadLittleEndianInt32: Integer;
    function ReadDouble: Double;
    procedure ReadHeader;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    
    function ReadNextPolygon(out APolygon: TShapePolygon): Boolean;
    procedure Reset;
    
    property ShapeType: Integer read FShapeType;
  end;

  // Rasteriseur OPTIMISÉ : scanline pour polygones simples, ray-casting pour trous
  TPolygonRasterizer = class
  private
    FWidth: Integer;
    FHeight: Integer;
    FBitmap: array of Byte;
    FSimplePolygonCount: Integer;
    FComplexPolygonCount: Integer;
    
    // Méthode RAPIDE pour polygones simples (sans trous)
    procedure FillSimplePolygon(const APixelPolygon: TPixelPolygon);
    procedure ScanLine(Y: Integer; const Points: TPixelPolygon);
    
    // Méthode LENTE pour polygones avec trous
    procedure FillPolygonWithHoles(const ARings: array of TPixelPolygon);
    function IsPointInRing(X, Y: Integer; const Ring: TPixelPolygon): Boolean;
  public
    constructor Create(AWidth, AHeight: Integer);
    destructor Destroy; override;
    
    procedure Clear;
    procedure AddPolygon(const AShapePolygon: TShapePolygon);
    procedure SaveToFile(const AFileName: string);
    procedure SaveToBMP(const AFileName: string);
    procedure SaveToPNG(const AFileName: string);
	
    function GetPixel(X, Y: Integer): Boolean;
    procedure SetPixel(X, Y: Integer; AValue: Boolean);
    
    property SimplePolygonCount: Integer read FSimplePolygonCount;
    property ComplexPolygonCount: Integer read FComplexPolygonCount;
  end;

implementation

uses
  Vcl.Imaging.pngimage;

{ TShapefileReader}

constructor TShapefileReader.Create(const AFileName: string);
begin
  inherited Create;
  FStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  ReadHeader;
end;

destructor TShapefileReader.Destroy;
begin
  FStream.Free;
  inherited;
end;

function TShapefileReader.ReadBigEndianInt32: Integer;
var
  Bytes: array[0..3] of Byte;
begin
  FStream.Read(Bytes, 4);
  Result := (Bytes[0] shl 24) or (Bytes[1] shl 16) or (Bytes[2] shl 8) or Bytes[3];
end;

function TShapefileReader.ReadLittleEndianInt32: Integer;
begin
  FStream.Read(Result, 4);
end;

function TShapefileReader.ReadDouble: Double;
begin
  FStream.Read(Result, 8);
end;

procedure TShapefileReader.ReadHeader;
var
  I: Integer;
begin
  ReadBigEndianInt32;
  for I := 1 to 5 do ReadBigEndianInt32;
  ReadBigEndianInt32;
  ReadLittleEndianInt32;
  FShapeType := ReadLittleEndianInt32;
  FBoundingBox[0] := ReadDouble;
  FBoundingBox[1] := ReadDouble;
  FBoundingBox[2] := ReadDouble;
  FBoundingBox[3] := ReadDouble;
  for I := 1 to 4 do ReadDouble;
end;

function TShapefileReader.ReadNextPolygon(out APolygon: TShapePolygon): Boolean;
var
//  RecordNumber, ContentLength, ShapeType: Integer;
  NumParts, NumPoints, I, PartIdx: Integer;
  Parts: array of Integer;
  Box: array[0..3] of Double;
  AllPoints: array of TShapePoint;
  StartIdx, EndIdx: Integer;
begin
  Result := False;
  APolygon.NumRings := 0;
  
  if FStream.Position >= FStream.Size then
    Exit;
  
  try
    // Pas utilisé ici...
    // RecordNumber := ReadBigEndianInt32;
    // ContentLength := ReadBigEndianInt32;
    // ShapeType := ReadLittleEndianInt32;
    // Remplacé par ceci pour éviter 2 warning.
    ReadBigEndianInt32;
    ReadBigEndianInt32;
    ReadLittleEndianInt32;

    if ShapeType = 0 then Exit;
    if ShapeType <> 5 then Exit;
    
    for I := 0 to 3 do
      Box[I] := ReadDouble;
    
    NumParts  := ReadLittleEndianInt32;
    NumPoints := ReadLittleEndianInt32;
    
    SetLength(Parts, NumParts);
    for I := 0 to NumParts - 1 do
      Parts[I] := ReadLittleEndianInt32;
    
    SetLength(AllPoints, NumPoints);
    for I := 0 to NumPoints - 1 do
    begin
      AllPoints[I].X := ReadDouble;
      AllPoints[I].Y := ReadDouble;
    end;
    
    SetLength(APolygon.Rings, NumParts);
    APolygon.NumRings := NumParts;
    
    for PartIdx := 0 to NumParts - 1 do
    begin
      StartIdx := Parts[PartIdx];
      if PartIdx < NumParts - 1 then
        EndIdx := Parts[PartIdx + 1] - 1
      else
        EndIdx := NumPoints - 1;
      
      SetLength(APolygon.Rings[PartIdx], EndIdx - StartIdx + 1);

      for I := StartIdx to EndIdx do
        APolygon.Rings[PartIdx][I - StartIdx] := AllPoints[I];
    end;
    
    Result := True;
    
  except
    Result := False;
  end;
end;

procedure TShapefileReader.Reset;
begin
  FStream.Position := 100;
end;

{ TPolygonRasterizer - Version OPTIMISÉE }

constructor TPolygonRasterizer.Create(AWidth, AHeight: Integer);
var
  BitmapSize: Int64;
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FSimplePolygonCount := 0;
  FComplexPolygonCount := 0;
  
  BitmapSize := ((Int64(FWidth) * FHeight) + 7) div 8;
  SetLength(FBitmap, BitmapSize);
  Clear;
end;

destructor TPolygonRasterizer.Destroy;
begin
  SetLength(FBitmap, 0);
  inherited;
end;

procedure TPolygonRasterizer.Clear;
begin
  FillChar(FBitmap[0], Length(FBitmap), 0);
end;

function TPolygonRasterizer.GetPixel(X, Y: Integer): Boolean;
var
  BitIndex: Integer;
  ByteIndex: Integer;
  BitMask: Byte;
begin
  if (X < 0) or (X >= FWidth) or (Y < 0) or (Y >= FHeight) then
  begin
    Result := False;
    Exit;
  end;
  
  BitIndex := Y * FWidth + X;
  ByteIndex := BitIndex div 8;
  BitMask := 1 shl (BitIndex mod 8);
  
  Result := (FBitmap[ByteIndex] and BitMask) <> 0;
end;

procedure TPolygonRasterizer.SetPixel(X, Y: Integer; AValue: Boolean);
var
  BitIndex: Integer;
  ByteIndex: Integer;
  BitMask: Byte;
begin
  if (X < 0) or (X >= FWidth) or (Y < 0) or (Y >= FHeight) then
    Exit;
  
  BitIndex := Y * FWidth + X;
  ByteIndex := BitIndex div 8;
  BitMask := 1 shl (BitIndex mod 8);
  
  if AValue then
    FBitmap[ByteIndex] := FBitmap[ByteIndex] or BitMask
  else
    FBitmap[ByteIndex] := FBitmap[ByteIndex] and not BitMask;
end;

procedure TPolygonRasterizer.AddPolygon(const AShapePolygon: TShapePolygon);
var
  PixelRings: array of TPixelPolygon;
  I, J: Integer;
  GeoRing: TGeoPolygon;
begin
  if AShapePolygon.NumRings = 0 then
    Exit;
  
  // Convertir tous les rings en coordonnées pixel
  SetLength(PixelRings, AShapePolygon.NumRings);
  
  for I := 0 to AShapePolygon.NumRings - 1 do
  begin
    SetLength(GeoRing, Length(AShapePolygon.Rings[I]));
    for J := 0 to High(AShapePolygon.Rings[I]) do
    begin
      GeoRing[J].Longitude := AShapePolygon.Rings[I][J].X;
      GeoRing[J].Latitude := AShapePolygon.Rings[I][J].Y;
    end;
    
    PixelRings[I] := TGeoConverter.GeoPolygonToPixel(GeoRing, FWidth, FHeight);
  end;
  
  // ✅ OPTIMISATION : Choisir l'algorithme selon le nombre de rings
  if AShapePolygon.NumRings = 1 then
  begin
    // Polygone simple (sans trous) → SCANLINE RAPIDE
    FillSimplePolygon(PixelRings[0]);
    Inc(FSimplePolygonCount);
  end
  else
  begin
    // Polygone avec trous → RAY-CASTING LENT
    FillPolygonWithHoles(PixelRings);
    Inc(FComplexPolygonCount);
  end;
end;

// ========== MÉTHODE RAPIDE : SCANLINE ==========

procedure TPolygonRasterizer.FillSimplePolygon(const APixelPolygon: TPixelPolygon);
var
  MinY, MaxY, Y: Integer;
  I: Integer;
begin
  if Length(APixelPolygon) < 3 then
    Exit;
  
  MinY := APixelPolygon[0].Y;
  MaxY := APixelPolygon[0].Y;
  
  for I := 1 to High(APixelPolygon) do
  begin
    if APixelPolygon[I].Y < MinY then MinY := APixelPolygon[I].Y;
    if APixelPolygon[I].Y > MaxY then MaxY := APixelPolygon[I].Y;
  end;
  
  if MinY < 0 then MinY := 0;
  if MaxY >= FHeight then MaxY := FHeight - 1;
  
  if (MinY >= FHeight) or (MaxY < 0) then
    Exit;
  
  for Y := MinY to MaxY do
    ScanLine(Y, APixelPolygon);
end;

procedure TPolygonRasterizer.ScanLine(Y: Integer; const Points: TPixelPolygon);
var
  Intersections: array of Integer;
  NumIntersections: Integer;
  I, J, X: Integer;
  X1, Y1, X2, Y2: Integer;
  XIntersect: Double;
  Temp: Integer;
begin
  if (Y < 0) or (Y >= FHeight) then
    Exit;
  
  SetLength(Intersections, Length(Points));
  NumIntersections := 0;
  
  for I := 0 to High(Points) do
  begin
    J := (I + 1) mod Length(Points);
    
    X1 := Points[I].X;
    Y1 := Points[I].Y;
    X2 := Points[J].X;
    Y2 := Points[J].Y;
    
    if ((Y1 <= Y) and (Y < Y2)) or ((Y2 <= Y) and (Y < Y1)) then
    begin
      if Y2 <> Y1 then
      begin
        XIntersect := X1 + (Y - Y1) * (X2 - X1) / (Y2 - Y1);
        Intersections[NumIntersections] := Round(XIntersect);
        Inc(NumIntersections);
      end;
    end;
  end;
  
  // Tri à bulles
  for I := 0 to NumIntersections - 2 do
    for J := I + 1 to NumIntersections - 1 do
      if Intersections[J] < Intersections[I] then
      begin
        Temp := Intersections[I];
        Intersections[I] := Intersections[J];
        Intersections[J] := Temp;
      end;
  
  I := 0;
  while I < NumIntersections - 1 do
  begin
    for X := Intersections[I] to Intersections[I + 1] - 1 do
      SetPixel(X, Y, True);
    Inc(I, 2);
  end;
end;

// ========== MÉTHODE LENTE : RAY-CASTING ==========

function TPolygonRasterizer.IsPointInRing(X, Y: Integer; const Ring: TPixelPolygon): Boolean;
var
  I, J: Integer;
  X1, Y1, X2, Y2: Integer;
  Intersections: Integer;
begin
  Intersections := 0;
  
  for I := 0 to High(Ring) do
  begin
    J := (I + 1) mod Length(Ring);
    
    X1 := Ring[I].X;
    Y1 := Ring[I].Y;
    X2 := Ring[J].X;
    Y2 := Ring[J].Y;
    
    if ((Y1 <= Y) and (Y < Y2)) or ((Y2 <= Y) and (Y < Y1)) then
    begin
      if Y2 <> Y1 then
      begin
        if X < (X1 + (Y - Y1) * (X2 - X1) / (Y2 - Y1)) then
          Inc(Intersections);
      end;
    end;
  end;
  
  Result := (Intersections mod 2) = 1;
end;

procedure TPolygonRasterizer.FillPolygonWithHoles(const ARings: array of TPixelPolygon);
var
  MinY, MaxY, Y, X: Integer;
  I, J: Integer;
  InOuterRing, InHole: Boolean;
begin
  if Length(ARings) = 0 then
    Exit;
  
  MinY := ARings[0][0].Y;
  MaxY := ARings[0][0].Y;
  
  for I := 0 to High(ARings) do
    for J := 0 to High(ARings[I]) do
    begin
      if ARings[I][J].Y < MinY then MinY := ARings[I][J].Y;
      if ARings[I][J].Y > MaxY then MaxY := ARings[I][J].Y;
    end;
  
  if MinY < 0 then MinY := 0;
  if MaxY >= FHeight then MaxY := FHeight - 1;
  
  for Y := MinY to MaxY do
  begin
    for X := 0 to FWidth - 1 do
    begin
      InOuterRing := IsPointInRing(X, Y, ARings[0]);
      
      if InOuterRing then
      begin
        InHole := False;
        for I := 1 to High(ARings) do
        begin
          if IsPointInRing(X, Y, ARings[I]) then
          begin
            InHole := True;
            Break;
          end;
        end;
        
        if not InHole then
          SetPixel(X, Y, True);
      end;
    end;
  end;
end;

procedure TPolygonRasterizer.SaveToFile(const AFileName: string);
var
  Stream: TFileStream;
  X, Y: Integer;
  Value: Byte;
begin
  Stream := TFileStream.Create(AFileName, fmCreate);
  try
    for Y := 0 to FHeight - 1 do
      for X := 0 to FWidth - 1 do
      begin
        if GetPixel(X, Y) then
          Value := 255
        else
          Value := 0;
        Stream.Write(Value, 1);
      end;
  finally
    Stream.Free;
  end;
end;

procedure TPolygonRasterizer.SaveToBMP(const AFileName: string);
var
  Bitmap: TBitmap;
  Y: Integer;
  ScanLine: PByteArray;
  X: Integer;
begin
  Bitmap := TBitmap.Create;
  try
    Bitmap.PixelFormat := pf24bit;
    Bitmap.Width := FWidth;
    Bitmap.Height := FHeight;
    
    for Y := 0 to FHeight - 1 do
    begin
      ScanLine := Bitmap.ScanLine[Y];
      
      for X := 0 to FWidth - 1 do
      begin
        if GetPixel(X, Y) then
        begin
          ScanLine[X * 3 + 0] := 200;
          ScanLine[X * 3 + 1] := 100;
          ScanLine[X * 3 + 2] := 50;
        end
        else
        begin
          ScanLine[X * 3 + 0] := 255;
          ScanLine[X * 3 + 1] := 255;
          ScanLine[X * 3 + 2] := 255;
        end;
      end;
    end;
    
    Bitmap.SaveToFile(AFileName);
    
  finally
    Bitmap.Free;
  end;
end;

procedure TPolygonRasterizer.SaveToPNG(const AFileName: string);
var
  PNG: TPngImage;
  Y: Integer;
  ScanLine: PByteArray;
  AlphaScanLine: PByteArray;
  X: Integer;
begin
  PNG := TPngImage.Create;
  try
    // Configurer le PNG en mode RGBA (avec canal alpha)
    PNG.CreateBlank(COLOR_RGBALPHA, 8, FWidth, FHeight);

    // Remplir pixel par pixel
    for Y := 0 to FHeight - 1 do
    begin
      ScanLine := PNG.ScanLine[Y];
      AlphaScanLine := PNG.AlphaScanLine[Y];

      for X := 0 to FWidth - 1 do
      begin
        if GetPixel(X, Y) then
        begin
          // Eau = Bleu
          ScanLine[X * 3 + 0] := 200; // B (Bleu fort)
          ScanLine[X * 3 + 1] := 50;  // G (Peu de vert)
          ScanLine[X * 3 + 2] := 50;  // R (Peu de rouge)

          // Opaque
          AlphaScanLine[X] := 255;
        end
        else
        begin
          // Terre = Transparent (la couleur n'a pas d'importance)
          ScanLine[X * 3 + 0] := 0;
          ScanLine[X * 3 + 1] := 0;
          ScanLine[X * 3 + 2] := 0;

          // Complètement transparent
          AlphaScanLine[X] := 0;
        end;
      end;
    end;

    PNG.SaveToFile(AFileName);

  finally
    PNG.Free;
  end;
end;

end.
