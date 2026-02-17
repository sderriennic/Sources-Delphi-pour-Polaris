unit GeoConverter;

interface

uses
  System.SysUtils, System.Math, System.Types, System.Classes;

const
  // Dimensions de la heightmap
  HEIGHTMAP_WIDTH  = 21600; // 4096; // 131072;
  HEIGHTMAP_HEIGHT = 10800; // 2048; // 65536;
  
  // Limites géographiques (monde entier)
  LON_MIN = -180.0;
  LON_MAX = 180.0;
  LAT_MIN = -90.0;
  LAT_MAX = 90.0;

type
  TGeoPoint = record
    Longitude: Double;
    Latitude: Double;
  end;

  TPixelPoint = record
    X: Integer;
    Y: Integer;
  end;

  TGeoPolygon = array of TGeoPoint;
  TPixelPolygon = array of TPixelPoint;

  TGeoConverter = class
  public
    // Conversion Latitude/Longitude vers coordonnées pixel
    class function GeoToPixel(const AGeoPoint: TGeoPoint): TPixelPoint; overload;
    class function GeoToPixel(ALongitude, ALatitude: Double): TPixelPoint; overload;
    class function GeoToPixel(const AGeoPoint: TGeoPoint; AWidth, AHeight: Integer): TPixelPoint; overload;
    class function GeoToPixel(ALongitude, ALatitude: Double; AWidth, AHeight: Integer): TPixelPoint; overload;
    
    // Conversion coordonnées pixel vers Latitude/Longitude
    class function PixelToGeo(const APixelPoint: TPixelPoint): TGeoPoint; overload;
    class function PixelToGeo(AX, AY: Integer): TGeoPoint; overload;
    
    // Conversion de polygones
    class function GeoPolygonToPixel(const AGeoPolygon: TGeoPolygon): TPixelPolygon; overload;
    class function GeoPolygonToPixel(const AGeoPolygon: TGeoPolygon; AWidth, AHeight: Integer): TPixelPolygon; overload;
    
    // Calcul de la résolution au sol (en mètres par pixel)
    class function GetGroundResolution(ALatitude: Double): Double;
    
    // Validation des coordonnées
    class function IsValidGeoPoint(const AGeoPoint: TGeoPoint): Boolean;
    class function IsValidPixelPoint(const APixelPoint: TPixelPoint): Boolean;
  end;

implementation

{ TGeoConverter }

class function TGeoConverter.GeoToPixel(const AGeoPoint: TGeoPoint): TPixelPoint;
begin
  Result := GeoToPixel(AGeoPoint.Longitude, AGeoPoint.Latitude);
end;

class function TGeoConverter.GeoToPixel(ALongitude, ALatitude: Double): TPixelPoint;
begin
  Result := GeoToPixel(ALongitude, ALatitude, HEIGHTMAP_WIDTH, HEIGHTMAP_HEIGHT);
end;

class function TGeoConverter.GeoToPixel(const AGeoPoint: TGeoPoint; AWidth, AHeight: Integer): TPixelPoint;
begin
  Result := GeoToPixel(AGeoPoint.Longitude, AGeoPoint.Latitude, AWidth, AHeight);
end;

class function TGeoConverter.GeoToPixel(ALongitude, ALatitude: Double; AWidth, AHeight: Integer): TPixelPoint;
var
  NormX, NormY: Double;
begin
  // Normalisation longitude: -180 à 180 -> 0 à WIDTH
  NormX := (ALongitude - LON_MIN) / (LON_MAX - LON_MIN);
  Result.X := Trunc(NormX * AWidth);
  
  // Normalisation latitude: 90 à -90 -> 0 à HEIGHT
  // Y=0 en haut (Nord), Y=HEIGHT-1 en bas (Sud)
  NormY := (LAT_MAX - ALatitude) / (LAT_MAX - LAT_MIN);
  Result.Y := Trunc(NormY * AHeight);
  
  // Clamp pour éviter les débordements
  if Result.X < 0 then Result.X := 0;
  if Result.X >= AWidth then Result.X := AWidth - 1;
  if Result.Y < 0 then Result.Y := 0;
  if Result.Y >= AHeight then Result.Y := AHeight - 1;
end;

class function TGeoConverter.PixelToGeo(const APixelPoint: TPixelPoint): TGeoPoint;
begin
  Result := PixelToGeo(APixelPoint.X, APixelPoint.Y);
end;

class function TGeoConverter.PixelToGeo(AX, AY: Integer): TGeoPoint;
begin
  // Conversion X -> Longitude
  Result.Longitude := LON_MIN + (AX / HEIGHTMAP_WIDTH) * (LON_MAX - LON_MIN);
  
  // Conversion Y -> Latitude
  Result.Latitude := LAT_MAX - (AY / HEIGHTMAP_HEIGHT) * (LAT_MAX - LAT_MIN);
end;

class function TGeoConverter.GeoPolygonToPixel(const AGeoPolygon: TGeoPolygon): TPixelPolygon;
begin
  Result := GeoPolygonToPixel(AGeoPolygon, HEIGHTMAP_WIDTH, HEIGHTMAP_HEIGHT);
end;

class function TGeoConverter.GeoPolygonToPixel(const AGeoPolygon: TGeoPolygon; AWidth, AHeight: Integer): TPixelPolygon;
var
  I: Integer;
begin
  SetLength(Result, Length(AGeoPolygon));
  for I := 0 to High(AGeoPolygon) do
    Result[I] := GeoToPixel(AGeoPolygon[I], AWidth, AHeight);
end;

class function TGeoConverter.GetGroundResolution(ALatitude: Double): Double;
const
  EARTH_CIRCUMFERENCE = 40075017.0; // mètres à l'équateur
var
  LatRad: Double;
begin
  // Résolution de base à l'équateur
  Result := EARTH_CIRCUMFERENCE / HEIGHTMAP_WIDTH;
  
  // Ajustement selon la latitude (projection Mercator)
  LatRad := DegToRad(ALatitude);
  Result := Result * Cos(LatRad);
end;

class function TGeoConverter.IsValidGeoPoint(const AGeoPoint: TGeoPoint): Boolean;
begin
  Result := (AGeoPoint.Longitude >= LON_MIN) and 
            (AGeoPoint.Longitude <= LON_MAX) and
            (AGeoPoint.Latitude >= LAT_MIN) and 
            (AGeoPoint.Latitude <= LAT_MAX);
end;

class function TGeoConverter.IsValidPixelPoint(const APixelPoint: TPixelPoint): Boolean;
begin
  Result := (APixelPoint.X >= 0) and 
            (APixelPoint.X < HEIGHTMAP_WIDTH) and
            (APixelPoint.Y >= 0) and 
            (APixelPoint.Y < HEIGHTMAP_HEIGHT);
end;

end.
