program LakesConverter;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  GeoConverter in 'GeoConverter.pas',
  ShapefileParser in 'ShapefileParser.pas';

procedure TestConversions;
var
  GeoPoint: TGeoPoint;
  PixelPoint: TPixelPoint;
  TestData: array[0..5] of record
    Name: string;
    Lon, Lat: Double;
  end;
  I: Integer;
begin
  WriteLn('=== TEST DES CONVERSIONS ===');
  WriteLn;
  
  // Points de test
  TestData[0].Name := 'Paris'; TestData[0].Lon := 2.3522; TestData[0].Lat := 48.8566;
  TestData[1].Name := 'New York'; TestData[1].Lon := -74.0060; TestData[1].Lat := 40.7128;
  TestData[2].Name := 'Tokyo'; TestData[2].Lon := 139.6917; TestData[2].Lat := 35.6895;
  TestData[3].Name := 'Lac Supérieur'; TestData[3].Lon := -87.5; TestData[3].Lat := 47.5;
  TestData[4].Name := 'Pôle Nord'; TestData[4].Lon := 0; TestData[4].Lat := 90;
  TestData[5].Name := 'Pôle Sud'; TestData[5].Lon := 0; TestData[5].Lat := -90;
  
  WriteLn('Résolution heightmap: ', HEIGHTMAP_WIDTH, 'x', HEIGHTMAP_HEIGHT);
  WriteLn('Résolution au sol (équateur): ~305 mètres/pixel');
  WriteLn;
  
  for I := 0 to High(TestData) do
  begin
    GeoPoint.Longitude := TestData[I].Lon;
    GeoPoint.Latitude := TestData[I].Lat;
    
    PixelPoint := TGeoConverter.GeoToPixel(GeoPoint);
    
    WriteLn(Format('%-15s (%8.4f°, %7.4f°) -> Pixel (%6d, %5d)',
      [TestData[I].Name, GeoPoint.Longitude, GeoPoint.Latitude, 
       PixelPoint.X, PixelPoint.Y]));
  end;
  
  WriteLn;
end;

procedure ConvertShapefileToMask(const AShapefilePath, AOutputPath: string; 
                                 const ABMPPath: string = '');
var
  Reader: TShapefileReader;
  Rasterizer: TPolygonRasterizer;
  Polygon: TShapePolygon;
  Count, DrawCount, InBoundsCount: Integer;
  I{, J, RingIdx}: Integer;
  PixelsSet: Int64;
  X, Y: Integer;
  TotalRings: Integer;
  PixelPolygon: TPixelPolygon;
  GeoPolygon: TGeoPolygon;
begin
  WriteLn('=== CONVERSION SHAPEFILE -> HEIGHTMAP (VERSION AVEC GESTION DES TROUS) ===');
  WriteLn;
  WriteLn('Fichier source: ', AShapefilePath);
  WriteLn('Fichier destination: ', AOutputPath);
  if ABMPPath <> '' then
    WriteLn('Fichier BMP: ', ABMPPath);
  WriteLn;
  
  Reader := TShapefileReader.Create(AShapefilePath);
  try
    WriteLn('Type de shape: ', Reader.ShapeType);
    WriteLn('ATTENTION: Version qui gère les îles dans les lacs (plus lent)');
    WriteLn;
    
    // Demander la résolution
    WriteLn('Résolutions disponibles:');
    WriteLn('  ' + HEIGHTMAP_WIDTH.ToString + 'x' + HEIGHTMAP_HEIGHT.ToString + '  (moyen, bonne qualité)');
    WriteLn;
    
    // Pour cet exemple, on utilise HEIGHTMAP_WIDTHx2048 par défaut
    WriteLn('Utilisation de ' + HEIGHTMAP_WIDTH.ToString + 'x' + HEIGHTMAP_HEIGHT.ToString + '...');
    Rasterizer := TPolygonRasterizer.Create(HEIGHTMAP_WIDTH, HEIGHTMAP_HEIGHT);
    try
      Count := 0;
      DrawCount := 0;
      InBoundsCount := 0;
      TotalRings := 0;
      Reader.Reset;
      
      WriteLn('Traitement des polygones...');
      WriteLn('  (Cette version est plus lente car elle gère les îles)');
      WriteLn;
      
      while Reader.ReadNextPolygon(Polygon) do
      begin
        Inc(Count);
        TotalRings := TotalRings + Polygon.NumRings;
        
        // Vérifier si au moins un point du premier ring est dans les limites
        if Polygon.NumRings > 0 then
        begin
          // Convertir le premier ring (contour externe) en GeoPolygon
          SetLength(GeoPolygon, Length(Polygon.Rings[0]));
          for I := 0 to High(Polygon.Rings[0]) do
          begin
            GeoPolygon[I].Longitude := Polygon.Rings[0][I].X;
            GeoPolygon[I].Latitude := Polygon.Rings[0][I].Y;
          end;
          
          // Convertir en pixels pour vérifier les limites
          PixelPolygon := TGeoConverter.GeoPolygonToPixel(GeoPolygon, HEIGHTMAP_WIDTH, 2048);
          
          // Vérifier si au moins un point est dans les limites
          for I := 0 to High(PixelPolygon) do
          begin
            if (PixelPolygon[I].X >= 0) and (PixelPolygon[I].X < HEIGHTMAP_WIDTH) and
               (PixelPolygon[I].Y >= 0) and (PixelPolygon[I].Y < HEIGHTMAP_HEIGHT) then
            begin
              Inc(InBoundsCount);
              Break;
            end;
          end;
        end;
        
        // Rasteriser le polygone avec tous ses rings
        Rasterizer.AddPolygon(Polygon);
        Inc(DrawCount);

        if (Count mod 10000) = 0 then
          WriteLn('  Lus: ', Count, ' | Dessinés: ', DrawCount, 
                  ' | Dans limites: ', InBoundsCount, ' | Rings: ', TotalRings);
      end;
      
      // Compter les pixels effectivement marqués comme lacs
      PixelsSet := 0;
      for Y := 0 to pred(HEIGHTMAP_HEIGHT) do
        for X := 0 to pred(HEIGHTMAP_WIDTH) do
          if Rasterizer.GetPixel(X, Y) then
            Inc(PixelsSet);
      
      WriteLn;
      WriteLn('═══════════════════════════════════════');
      WriteLn('  Lacs trouvés:       ', Count);
      WriteLn('  Lacs dessinés:      ', DrawCount);
      WriteLn('  Lacs dans limites:  ', InBoundsCount);
      WriteLn('  Total rings:        ', TotalRings);
      WriteLn('  Pixels eau:         ', PixelsSet);
      WriteLn('  % surface eau:      ', (PixelsSet * 100.0 / (HEIGHTMAP_WIDTH * HEIGHTMAP_HEIGHT)):0:2, '%');
      WriteLn('═══════════════════════════════════════');
      WriteLn;
      
      if PixelsSet = 0 then
      begin
        WriteLn('ATTENTION: Aucun pixel d''eau détecté !');
        WriteLn;
      end;
      
      WriteLn('Sauvegarde du masque...');
      
      Rasterizer.SaveToFile(AOutputPath);
      WriteLn('✓ Fichier RAW créé: ', AOutputPath);
      
      // Sauvegarder en BMP si demandé
      if ABMPPath <> '' then
      begin
        if LowerCase(ExtractFileExt(ABMPPath)) = '.png' then
        begin
          WriteLn('Sauvegarde du PNG...');
          Rasterizer.SaveToPNG(ABMPPath);
          WriteLn('✓ Fichier PNG créé: ', ABMPPath);
        end
        else
        begin
          WriteLn('Sauvegarde du BMP...');
          Rasterizer.SaveToBMP(ABMPPath);
          WriteLn('✓ Fichier BMP créé: ', ABMPPath);
        end;
      end;
      
      WriteLn;
      WriteLn('✓ Terminé !');
      WriteLn('  Note: Les îles dans les lacs sont maintenant correctement représentées');
      WriteLn('        (zones de terre à l''intérieur des lacs)');
      
    finally
      Rasterizer.Free;
    end;
  finally
    Reader.Free;
  end;
end;

procedure ShowUsage;
begin
  WriteLn('USAGE:');
  WriteLn('  LakesConverterFixed.exe test                    - Tester les conversions');
  WriteLn('  LakesConverterFixed.exe convert <input> <o> - Convertir shapefile');
  WriteLn('  LakesConverterFixed.exe convert <input> <o> <bmp> - Avec export BMP');
  WriteLn('  LakesConverterFixed.exe convert <input> <o> <bmp> - Avec export PNG');
  WriteLn;
  WriteLn('EXEMPLES:');
  WriteLn('  LakesConverterFixed.exe test');
  WriteLn('  LakesConverterFixed.exe convert lakes.shp lakes_mask.raw');
  WriteLn('  LakesConverterFixed.exe convert lakes.shp lakes_mask.raw preview.bmp');
  WriteLn('  LakesConverterFixed.exe convert lakes.shp lakes_mask.raw preview.png');
  WriteLn;
  WriteLn('VERSION: Gestion des îles dans les lacs (plus lent mais correct)');
  WriteLn;
end;

var
  Command: string;
begin
  try
    WriteLn('╔════════════════════════════════════════════════════════════╗');
    WriteLn('║  CONVERTISSEUR LACS avec GESTION DES ÎLES                  ║');
    WriteLn('║  Version corrigée - Ray-casting pour les trous             ║');
    WriteLn('╚════════════════════════════════════════════════════════════╝');
    WriteLn;
    
    if ParamCount = 0 then
    begin
      ShowUsage;
      Exit;
    end;
    
    Command := LowerCase(ParamStr(1));
    
    if Command = 'test' then
    begin
      TestConversions;
    end
    else if (Command = 'convert') and (ParamCount >= 3) then
    begin
      if ParamCount >= 4 then
        ConvertShapefileToMask(ParamStr(2), ParamStr(3), ParamStr(4))
      else
        ConvertShapefileToMask(ParamStr(2), ParamStr(3));
    end
    else
    begin
      ShowUsage;
    end;
    
  except
    on E: Exception do
    begin
      WriteLn;
      WriteLn('ERREUR: ', E.Message);
      ExitCode := 1;
    end;
  end;
  
  WriteLn;
  WriteLn('Appuyez sur Entrée pour quitter...');
  ReadLn;
end.
