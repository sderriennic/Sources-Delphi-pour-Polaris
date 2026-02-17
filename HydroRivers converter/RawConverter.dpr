program RawConverter;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  RawToImageConverter in 'RawToImageConverter.pas';

procedure ShowUsage;
begin
  WriteLn('╔════════════════════════════════════════════════════════════╗');
  WriteLn('║         CONVERTISSEUR RAW → BMP/PNG                       ║');
  WriteLn('╚════════════════════════════════════════════════════════════╝');
  WriteLn;
  WriteLn('USAGE:');
  WriteLn('  RawConverter.exe <input.raw> <width> <height> <format> <output>');
  WriteLn;
  WriteLn('FORMATS:');
  WriteLn('  bmp       - Bitmap avec fond terre');
  WriteLn('  png       - PNG avec fond terre');
  WriteLn('  png-t     - PNG transparent (seule l''eau visible)');
  WriteLn;
  WriteLn('EXEMPLES:');
  WriteLn('  RawConverter.exe lakes.raw 4096 2048 bmp preview.bmp');
  WriteLn('  RawConverter.exe lakes.raw 4096 2048 png preview.png');
  WriteLn('  RawConverter.exe lakes.raw 4096 2048 png-t lakes_transparent.png');
  WriteLn('  RawConverter.exe lakes.raw 21600 10800 png-t lakes_21k.png');
  WriteLn;
  WriteLn('COULEURS PAR DÉFAUT:');
  WriteLn('  Eau:   Bleu ciel RGB(100, 200, 255)');
  WriteLn('  Terre: Beige    RGB(160, 200, 220)');
  WriteLn;
end;

procedure ConvertRaw(const AInputFile: string; AWidth, AHeight: Integer;
                     const AFormat, AOutputFile: string);
var
  Converter: TRawToImageConverter;
  StartTime: TDateTime;
  ElapsedSeconds: Double;
begin
  WriteLn('═══════════════════════════════════════════════════════════');
  WriteLn('CONVERSION RAW → ', UpperCase(AFormat));
  WriteLn('═══════════════════════════════════════════════════════════');
  WriteLn;
  WriteLn('Fichier source : ', AInputFile);
  WriteLn('Dimensions     : ', AWidth, ' × ', AHeight);
  WriteLn('Format sortie  : ', AFormat);
  WriteLn('Fichier sortie : ', AOutputFile);
  WriteLn;
  
  Converter := TRawToImageConverter.Create(AWidth, AHeight);
  try
    WriteLn('Chargement du fichier RAW...');
    StartTime := Now;
    
    Converter.LoadFromFile(AInputFile);
    WriteLn('✓ Chargé : ', (AWidth * AHeight), ' pixels');
    WriteLn;
    
    WriteLn('Conversion en ', AFormat, '...');
    
    if AFormat = 'bmp' then
    begin
      Converter.SaveToBMP(AOutputFile);
    end
    else if AFormat = 'png' then
    begin
      Converter.SaveToPNGWithBackground(AOutputFile);
    end
    else if AFormat = 'png-t' then
    begin
      Converter.SaveToPNGTransparent(AOutputFile);
    end
    else
    begin
      raise Exception.CreateFmt('Format inconnu: %s', [AFormat]);
    end;
    
    ElapsedSeconds := (Now - StartTime) * 24 * 60 * 60;
    
    WriteLn('✓ Conversion terminée en ', ElapsedSeconds:0:2, ' secondes');
    WriteLn;
    WriteLn('Fichier créé : ', AOutputFile);
    
    if FileExists(AOutputFile) then
    begin
      WriteLn('Taille       : ', (FileSize(AOutputFile) div 1024), ' KB');
    end;
    
  finally
    Converter.Free;
  end;
  
  WriteLn;
  WriteLn('═══════════════════════════════════════════════════════════');
  WriteLn('✓ SUCCÈS !');
  WriteLn('═══════════════════════════════════════════════════════════');
end;

function FileSize(const AFileName: string): Int64;
var
  SR: TSearchRec;
begin
  if FindFirst(AFileName, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    FindClose(SR);
  end
  else
    Result := 0;
end;

var
  InputFile, OutputFile, Format: string;
  Width, Height: Integer;
begin
  try
    if ParamCount < 5 then
    begin
      ShowUsage;
      Exit;
    end;
    
    InputFile := ParamStr(1);
    Width := StrToInt(ParamStr(2));
    Height := StrToInt(ParamStr(3));
    Format := LowerCase(ParamStr(4));
    OutputFile := ParamStr(5);
    
    // Validation
    if not FileExists(InputFile) then
    begin
      WriteLn('ERREUR: Fichier non trouvé: ', InputFile);
      ExitCode := 1;
      Exit;
    end;
    
    if (Width <= 0) or (Height <= 0) then
    begin
      WriteLn('ERREUR: Dimensions invalides');
      ExitCode := 1;
      Exit;
    end;
    
    if not (Format = 'bmp') and not (Format = 'png') and not (Format = 'png-t') then
    begin
      WriteLn('ERREUR: Format invalide. Utilisez: bmp, png ou png-t');
      ExitCode := 1;
      Exit;
    end;
    
    ConvertRaw(InputFile, Width, Height, Format, OutputFile);
    
  except
    on E: Exception do
    begin
      WriteLn;
      WriteLn('═══════════════════════════════════════════════════════════');
      WriteLn('ERREUR: ', E.Message);
      WriteLn('═══════════════════════════════════════════════════════════');
      ExitCode := 1;
    end;
  end;
  
  WriteLn;
  WriteLn('Appuyez sur Entrée pour quitter...');
  ReadLn;
end.
