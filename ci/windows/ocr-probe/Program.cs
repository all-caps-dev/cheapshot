// C#. Answers one question from the cheapshot Windows investigation (section 7, open question 1):
// does Windows.Media.Ocr work from a plain unpackaged exe, or does it need package identity (MSIX)?
//
// Usage: dotnet run --project ci/windows/ocr-probe -- <image.png>
//
// Prints one verdict line, "OCR_PROBE: <verdict>", where verdict is one of
//   worked            OCR ran and found the expected word "cheapshot"
//   worked-wrong-text OCR ran but did not find "cheapshot" (runs unpackaged; accuracy question)
//   needs-packaging   the call failed for lack of package identity
//   no-language       no OCR language pack is installed for the user or en-US
//   error             anything else (the stage and exception are printed)
// It always exits 0: the probe reports, it never fails the CI job.
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage;

const string Expected = "cheapshot";
// HRESULT 0x80073D54, APPMODEL_ERROR_NO_PACKAGE: "The process has no package identity."
const int NoPackageIdentity = unchecked((int)0x80073D54);

string stage = "start";
string verdict;
string detail = "";
try
{
    if (args.Length < 1) { Console.WriteLine("usage: OcrProbe <image>"); return 0; }
    string path = Path.GetFullPath(args[0]);
    Console.WriteLine($"image: {path}");
    Console.WriteLine($"package identity: {HasPackageIdentity()}");

    // Which recognizer languages Windows reports. Empty means no OCR language pack.
    stage = "languages";
    var langs = OcrEngine.AvailableRecognizerLanguages.Select(l => l.LanguageTag).ToList();
    Console.WriteLine($"recognizer languages: {(langs.Count == 0 ? "(none)" : string.Join(", ", langs))}");
    Console.WriteLine($"max image dimension: {OcrEngine.MaxImageDimension}");

    // Decode the PNG with WinRT, the same route the real Windows backend would take.
    stage = "decode";
    StorageFile file = await StorageFile.GetFileFromPathAsync(path);
    using var stream = await file.OpenAsync(FileAccessMode.Read);
    BitmapDecoder decoder = await BitmapDecoder.CreateAsync(stream);
    using SoftwareBitmap raw = await decoder.GetSoftwareBitmapAsync();
    // OcrEngine takes Bgra8 or Gray8; convert so any PNG layout works.
    using SoftwareBitmap bitmap = SoftwareBitmap.Convert(raw, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
    Console.WriteLine($"decoded: {bitmap.PixelWidth}x{bitmap.PixelHeight}");

    stage = "engine";
    OcrEngine? engine = OcrEngine.TryCreateFromUserProfileLanguages()
        ?? OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language("en-US"));
    if (engine is null)
    {
        verdict = "no-language";
    }
    else
    {
        Console.WriteLine($"engine language: {engine.RecognizerLanguage.LanguageTag}");
        stage = "recognize";
        OcrResult result = await engine.RecognizeAsync(bitmap);
        foreach (OcrLine line in result.Lines)
        {
            // Word boxes are what cheapshot's layout needs (cell widths); print the first one.
            var b = line.Words.Count > 0 ? line.Words[0].BoundingRect : default;
            // No recognised text in the log: CI logs are public, and a real screenshot passed here
            // could hold secrets. Shape only; the verdict below says whether the expected text was found.
            Console.WriteLine($"line: words {line.Words.Count}, first word box x={b.X:0} y={b.Y:0} w={b.Width:0} h={b.Height:0}");
        }
        bool found = result.Lines.Any(l => l.Text.Contains(Expected, StringComparison.OrdinalIgnoreCase));
        verdict = found ? "worked" : "worked-wrong-text";
        detail = $"{result.Lines.Count} lines";
    }
}
catch (Exception e) when (e.HResult == NoPackageIdentity
                          || e.Message.Contains("package identity", StringComparison.OrdinalIgnoreCase))
{
    verdict = "needs-packaging";
    detail = $"stage {stage}: 0x{e.HResult:X8} {e.Message.Trim()}";
}
catch (Exception e)
{
    verdict = "error";
    detail = $"stage {stage}: {e.GetType().Name} 0x{e.HResult:X8} {e.Message.Trim()}";
}

string summary = $"OCR_PROBE: {verdict}{(detail.Length > 0 ? " (" + detail + ")" : "")}";
Console.WriteLine(summary);
// On GitHub Actions, also put the verdict on the run's summary page.
string? stepSummary = Environment.GetEnvironmentVariable("GITHUB_STEP_SUMMARY");
if (!string.IsNullOrEmpty(stepSummary))
{
    File.AppendAllText(stepSummary, $"### Windows.Media.Ocr from an unpackaged exe\n\n`{summary}`\n");
}
return 0;

// True when the process runs with package identity. An unpackaged exe throws here.
static bool HasPackageIdentity()
{
    try { _ = Windows.ApplicationModel.Package.Current.Id; return true; }
    catch { return false; }
}
