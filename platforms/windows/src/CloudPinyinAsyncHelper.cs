using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

internal static class CloudPinyinAsyncHelper
{
    private const string RequestFileName = "cloud_pinyin_async.request";
    private const string ResponseFileName = "cloud_pinyin_async.response";
    private const string HeartbeatFileName = "cloud_pinyin_async.heartbeat";
    private const string LogFileName = "cloud_pinyin_async.log";
    private const string ResponseMagic = "RIME_CLOUD_V1";
    private const byte VirtualKeyF24 = 0x87;
    private const uint KeyEventKeyUp = 0x0002;

    private static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(false);
    private static readonly object LogLock = new object();

    private static string _userDirectory;
    private static string _requestPath;
    private static string _responsePath;
    private static string _heartbeatPath;
    private static string _logPath;

    private sealed class RequestState
    {
        public string Id;
        public string ContextInput;
        public string QueryInput;
        public int DelayMilliseconds;
        public int TimeoutMilliseconds;
        public int CandidatesPerSource;
        public int MaxCandidates;
        public DateTime ModifiedUtc;
        public IntPtr ForegroundWindow;
    }

    private sealed class CandidateRecord
    {
        public string Text;
        public string Pinyin;
        public bool FromSogou;
        public bool FromGoogle;

        public string SourceCode
        {
            get
            {
                if (FromSogou && FromGoogle)
                    return "SG+GG";
                if (FromSogou)
                    return "SG";
                return "GG";
            }
        }
    }

    private sealed class ProviderResult
    {
        public string Provider;
        public string Status;
        public long ElapsedMilliseconds;
        public List<CandidateRecord> Candidates = new List<CandidateRecord>();
    }

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr window, out Rect rectangle);

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Length < 1 || string.IsNullOrWhiteSpace(args[0]))
            return;

        _userDirectory = Path.GetFullPath(args[0]);
        _requestPath = Path.Combine(_userDirectory, RequestFileName);
        _responsePath = Path.Combine(_userDirectory, ResponseFileName);
        _heartbeatPath = Path.Combine(_userDirectory, HeartbeatFileName);
        _logPath = Path.Combine(_userDirectory, LogFileName);

        bool ownsMutex;
        using (Mutex mutex = new Mutex(true, @"Local\RimeCloudPinyinAsyncHelper", out ownsMutex))
        {
            if (!ownsMutex)
                return;

            try
            {
                ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
                ServicePointManager.DefaultConnectionLimit = 8;
                ServicePointManager.Expect100Continue = false;
                Log("helper started, pid=" + Process.GetCurrentProcess().Id);
                RunLoop();
            }
            catch (Exception exception)
            {
                Log("fatal: " + exception);
            }
            finally
            {
                try
                {
                    mutex.ReleaseMutex();
                }
                catch
                {
                }
            }
        }
    }

    private static void RunLoop()
    {
        string observedRequestId = null;
        DateTime nextHeartbeat = DateTime.MinValue;
        RequestState pending = null;

        for (;;)
        {
            DateTime now = DateTime.UtcNow;
            if (now >= nextHeartbeat)
            {
                WriteHeartbeat();
                nextHeartbeat = now.AddSeconds(2);
            }

            RequestState current = ReadRequest();
            if (current != null && !string.Equals(current.Id, observedRequestId, StringComparison.Ordinal))
            {
                observedRequestId = current.Id;
                current.ForegroundWindow = GetForegroundWindow();
                pending = current;

                if (string.IsNullOrEmpty(current.QueryInput))
                {
                    TruncateResponse();
                    pending = null;
                }
            }

            if (pending != null)
            {
                DateTime due = pending.ModifiedUtc.AddMilliseconds(pending.DelayMilliseconds);
                if (now >= due)
                {
                    RequestState job = pending;
                    pending = null;
                    ProcessRequest(job);
                }
            }

            Thread.Sleep(20);
        }
    }

    private static RequestState ReadRequest()
    {
        try
        {
            if (!File.Exists(_requestPath))
                return null;

            string line;
            using (FileStream stream = new FileStream(
                _requestPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader reader = new StreamReader(stream, Utf8NoBom, true))
                line = reader.ReadToEnd().TrimEnd('\r', '\n');
            string[] fields = line.Split('\t');
            if (fields.Length < 7 || string.IsNullOrEmpty(fields[0]))
                return null;

            return new RequestState
            {
                Id = fields[0],
                ContextInput = fields[1],
                QueryInput = fields[2],
                DelayMilliseconds = Clamp(ParseInt(fields[3], 500), 100, 3000),
                TimeoutMilliseconds = Clamp(ParseInt(fields[4], 900), 200, 5000),
                CandidatesPerSource = Clamp(ParseInt(fields[5], 5), 1, 10),
                MaxCandidates = Clamp(ParseInt(fields[6], 8), 1, 20),
                ModifiedUtc = File.GetLastWriteTimeUtc(_requestPath)
            };
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
        catch (Exception exception)
        {
            Log("read request failed: " + exception.Message);
            return null;
        }
    }

    private static void ProcessRequest(RequestState request)
    {
        Log("query begin id=" + request.Id + " length=" + request.QueryInput.Length);

        Task<ProviderResult> sogouTask = Task.Factory.StartNew(
            delegate { return FetchSogou(request.QueryInput, request.CandidatesPerSource, request.TimeoutMilliseconds); });
        Task<ProviderResult> googleTask = Task.Factory.StartNew(
            delegate { return FetchGoogle(request.QueryInput, request.CandidatesPerSource, request.TimeoutMilliseconds); });

        List<Task<ProviderResult>> outstanding = new List<Task<ProviderResult>> { sogouTask, googleTask };
        List<CandidateRecord> merged = new List<CandidateRecord>();
        Dictionary<string, CandidateRecord> byText = new Dictionary<string, CandidateRecord>(StringComparer.Ordinal);
        string sogouStatus = "pending";
        string googleStatus = "pending";
        long sogouMilliseconds = -1;
        long googleMilliseconds = -1;
        int revision = 0;
        string previousSignature = null;

        while (outstanding.Count > 0)
        {
            int completedIndex = Task.WaitAny(outstanding.ToArray());
            Task<ProviderResult> completedTask = outstanding[completedIndex];
            outstanding.RemoveAt(completedIndex);

            ProviderResult result;
            try
            {
                result = completedTask.Result;
            }
            catch (Exception exception)
            {
                result = new ProviderResult
                {
                    Provider = "unknown",
                    Status = "task_error:" + exception.GetType().Name,
                    ElapsedMilliseconds = -1
                };
            }

            if (string.Equals(result.Provider, "sogou", StringComparison.Ordinal))
            {
                sogouStatus = result.Status;
                sogouMilliseconds = result.ElapsedMilliseconds;
            }
            else if (string.Equals(result.Provider, "google", StringComparison.Ordinal))
            {
                googleStatus = result.Status;
                googleMilliseconds = result.ElapsedMilliseconds;
            }

            MergeCandidates(merged, byText, result.Candidates, request.MaxCandidates);

            RequestState latest = ReadRequest();
            if (latest == null || !string.Equals(latest.Id, request.Id, StringComparison.Ordinal))
            {
                Log("query stale id=" + request.Id + ", result discarded");
                return;
            }

            if (merged.Count == 0)
                continue;

            string signature = CandidateSignature(merged);
            if (string.Equals(signature, previousSignature, StringComparison.Ordinal))
                continue;

            previousSignature = signature;
            revision++;
            WriteResponse(request, revision, merged, sogouMilliseconds, googleMilliseconds, sogouStatus, googleStatus);

            bool sameForeground = GetForegroundWindow() == request.ForegroundWindow;
            bool panelDetected = IsWeaselPanelVisible();
            if (sameForeground)
            {
                SendF24();
                Log(
                    "refresh sent id=" + request.Id +
                    " rev=" + revision +
                    " panel_detected=" + panelDetected);
            }
            else
            {
                Log(
                    "refresh suppressed id=" + request.Id +
                    " rev=" + revision +
                    " reason=foreground_changed");
            }

            Log(
                "query publish id=" + request.Id +
                " rev=" + revision +
                " count=" + merged.Count +
                " sogou=" + sogouStatus + "/" + sogouMilliseconds + "ms" +
                " google=" + googleStatus + "/" + googleMilliseconds + "ms");
        }

        if (merged.Count == 0)
        {
            Log(
                "query empty id=" + request.Id +
                " sogou=" + sogouStatus +
                " google=" + googleStatus);
        }
    }

    private static ProviderResult FetchGoogle(string input, int count, int timeoutMilliseconds)
    {
        Stopwatch stopwatch = Stopwatch.StartNew();
        ProviderResult result = new ProviderResult { Provider = "google", Status = "empty" };

        try
        {
            string url =
                "https://inputtools.google.com/request?text=" + Uri.EscapeDataString(input) +
                "&itc=zh-t-i0-pinyin&num=" + count +
                "&cp=0&cs=1&ie=utf-8&oe=utf-8";
            HttpWebRequest request = CreateRequest(url, "GET", timeoutMilliseconds);

            byte[] body = ReadResponseBytes(request);
            result.Candidates = ParseGoogle(body, input, count);
            result.Status = result.Candidates.Count > 0 ? "ok" : "empty";
        }
        catch (WebException exception)
        {
            result.Status = WebExceptionStatus(exception);
        }
        catch (Exception exception)
        {
            result.Status = "error:" + exception.GetType().Name;
        }
        finally
        {
            stopwatch.Stop();
            result.ElapsedMilliseconds = stopwatch.ElapsedMilliseconds;
        }

        return result;
    }

    private static ProviderResult FetchSogou(string input, int count, int timeoutMilliseconds)
    {
        Stopwatch stopwatch = Stopwatch.StartNew();
        ProviderResult result = new ProviderResult { Provider = "sogou", Status = "empty" };

        for (int attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                int remainingMilliseconds = Math.Max(200, timeoutMilliseconds - (int)stopwatch.ElapsedMilliseconds);
                string url =
                    "https://shouji.sogou.com/web_ime/mobile.php" +
                    "?durtot=0&h=000000000000000&r=store_mf_wandoujia&v=3.7";
                byte[] payload = BuildSogouPayload(input);
                HttpWebRequest request = CreateRequest(url, "POST", remainingMilliseconds);
                request.ContentType = "application/x-www-form-urlencoded";
                request.ContentLength = payload.Length;
                request.ServicePoint.Expect100Continue = false;

                using (Stream stream = request.GetRequestStream())
                    stream.Write(payload, 0, payload.Length);

                byte[] body = ReadResponseBytes(request);
                result.Candidates = ParseSogou(body, input, count);
                result.Status = result.Candidates.Count > 0 ? "ok" : "empty";
                break;
            }
            catch (WebException exception)
            {
                result.Status = WebExceptionStatus(exception);
                // The unofficial mobile endpoint intermittently answers 400
                // for an otherwise valid packet. One bounded retry keeps the
                // fast source useful without ever delaying the input thread.
                if (attempt == 0 && result.Status == "http_400" && stopwatch.ElapsedMilliseconds < timeoutMilliseconds - 200)
                {
                    Thread.Sleep(40);
                    continue;
                }
                break;
            }
            catch (Exception exception)
            {
                result.Status = "error:" + exception.GetType().Name;
                break;
            }
        }

        stopwatch.Stop();
        result.ElapsedMilliseconds = stopwatch.ElapsedMilliseconds;

        return result;
    }

    private static HttpWebRequest CreateRequest(string url, string method, int timeoutMilliseconds)
    {
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
        request.Method = method;
        request.Timeout = timeoutMilliseconds;
        request.ReadWriteTimeout = timeoutMilliseconds;
        // The private Sogou mobile endpoint rejects non-browser user agents.
        request.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36";
        request.Accept = "*/*";
        request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
        request.KeepAlive = true;
        return request;
    }

    private static byte[] ReadResponseBytes(HttpWebRequest request)
    {
        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        using (Stream responseStream = response.GetResponseStream())
        using (MemoryStream memory = new MemoryStream())
        {
            if (responseStream != null)
                responseStream.CopyTo(memory);
            return memory.ToArray();
        }
    }

    private static byte[] BuildSogouPayload(string input)
    {
        byte[] key = Encoding.ASCII.GetBytes(input);
        if (key.Length > 255)
            throw new InvalidOperationException("Sogou input is too long.");

        byte[] token = { 0, 5, 0, 0, 0, 0, 1 };
        int totalLength = token.Length + key.Length + 3;
        byte[] payload = new byte[totalLength];
        int position = 0;
        payload[position++] = (byte)totalLength;
        Buffer.BlockCopy(token, 0, payload, position, token.Length);
        position += token.Length;
        payload[position++] = (byte)key.Length;
        Buffer.BlockCopy(key, 0, payload, position, key.Length);
        position += key.Length;

        byte check = 0;
        for (int index = 0; index < position; index++)
            check ^= payload[index];
        payload[position] = check;
        return payload;
    }

    private static List<CandidateRecord> ParseSogou(byte[] body, string input, int count)
    {
        List<CandidateRecord> candidates = new List<CandidateRecord>();
        if (body == null || body.Length < 0x16)
            return candidates;
        if (body[0] + 2 != body.Length)
            return candidates;

        int numberOfWords = ReadUInt16(body, 0x12);
        if (numberOfWords <= 0 || numberOfWords > 32)
            return candidates;

        int position = 0x14;
        for (int index = 0; index < numberOfWords && candidates.Count < count; index++)
        {
            int wordLength = ReadUInt16(body, position);
            position += 2;
            EnsureAvailable(body, position, wordLength);
            string word = Encoding.Unicode.GetString(body, position, wordLength);
            position += wordLength;

            int unknownLength = ReadUInt16(body, position);
            position += 2;
            EnsureAvailable(body, position, unknownLength);
            position += unknownLength;

            unknownLength = ReadUInt16(body, position);
            position += 2;
            EnsureAvailable(body, position, unknownLength + 1);
            position += unknownLength + 1;

            if (!string.IsNullOrEmpty(word))
            {
                candidates.Add(new CandidateRecord
                {
                    Text = word,
                    Pinyin = input,
                    FromSogou = true
                });
            }
        }

        return candidates;
    }

    private static List<CandidateRecord> ParseGoogle(byte[] body, string input, int count)
    {
        List<CandidateRecord> candidates = new List<CandidateRecord>();
        if (body == null || body.Length == 0)
            return candidates;

        string jsonText = Utf8NoBom.GetString(body);
        JavaScriptSerializer serializer = new JavaScriptSerializer();
        object[] root = serializer.DeserializeObject(jsonText) as object[];
        if (root == null || root.Length < 2 || !string.Equals(root[0] as string, "SUCCESS", StringComparison.Ordinal))
            return candidates;

        object[] blocks = root[1] as object[];
        if (blocks == null || blocks.Length == 0)
            return candidates;
        object[] block = blocks[0] as object[];
        if (block == null || block.Length < 2)
            return candidates;

        object[] words = block[1] as object[];
        Dictionary<string, object> metadata = block.Length > 3 ? block[3] as Dictionary<string, object> : null;
        object[] annotations = GetArray(metadata, "annotation");
        object[] matchedLengths = GetArray(metadata, "matched_length");
        if (words == null)
            return candidates;

        for (int index = 0; index < words.Length && candidates.Count < count; index++)
        {
            string word = words[index] as string;
            if (string.IsNullOrEmpty(word))
                continue;

            int matchedLength = input.Length;
            if (matchedLengths != null && index < matchedLengths.Length)
                matchedLength = Convert.ToInt32(matchedLengths[index]);
            if (matchedLength != input.Length)
                continue;

            string pinyin = input;
            if (annotations != null && index < annotations.Length && annotations[index] is string)
                pinyin = (string)annotations[index];

            candidates.Add(new CandidateRecord
            {
                Text = word,
                Pinyin = pinyin,
                FromGoogle = true
            });
        }

        return candidates;
    }

    private static object[] GetArray(Dictionary<string, object> dictionary, string key)
    {
        if (dictionary == null)
            return null;
        object value;
        if (!dictionary.TryGetValue(key, out value))
            return null;
        return value as object[];
    }

    private static void MergeCandidates(
        List<CandidateRecord> merged,
        Dictionary<string, CandidateRecord> byText,
        List<CandidateRecord> incoming,
        int maximum)
    {
        foreach (CandidateRecord candidate in incoming)
        {
            CandidateRecord existing;
            if (byText.TryGetValue(candidate.Text, out existing))
            {
                existing.FromSogou = existing.FromSogou || candidate.FromSogou;
                existing.FromGoogle = existing.FromGoogle || candidate.FromGoogle;
                if (candidate.FromGoogle && !string.IsNullOrWhiteSpace(candidate.Pinyin))
                    existing.Pinyin = candidate.Pinyin;
                continue;
            }

            if (merged.Count >= maximum)
                continue;

            merged.Add(candidate);
            byText[candidate.Text] = candidate;
        }
    }

    private static string CandidateSignature(List<CandidateRecord> candidates)
    {
        StringBuilder builder = new StringBuilder();
        foreach (CandidateRecord candidate in candidates)
        {
            builder.Append(candidate.Text);
            builder.Append('\u001f');
            builder.Append(candidate.Pinyin);
            builder.Append('\u001f');
            builder.Append(candidate.SourceCode);
            builder.Append('\u001e');
        }
        return builder.ToString();
    }

    private static void WriteResponse(
        RequestState request,
        int revision,
        List<CandidateRecord> candidates,
        long sogouMilliseconds,
        long googleMilliseconds,
        string sogouStatus,
        string googleStatus)
    {
        StringBuilder builder = new StringBuilder();
        builder.Append(ResponseMagic).Append('\t');
        builder.Append(request.Id).Append('\t');
        builder.Append(request.ContextInput).Append('\t');
        builder.Append(request.QueryInput).Append('\t');
        builder.Append(revision).Append('\t');
        builder.Append(sogouMilliseconds).Append('\t');
        builder.Append(googleMilliseconds).Append('\t');
        builder.Append(SanitizeStatus(sogouStatus)).Append('\t');
        builder.Append(SanitizeStatus(googleStatus)).AppendLine();

        foreach (CandidateRecord candidate in candidates)
        {
            builder.Append("C\t");
            builder.Append(ToBase64(candidate.Text)).Append('\t');
            builder.Append(ToBase64(candidate.Pinyin ?? string.Empty)).Append('\t');
            builder.Append(candidate.SourceCode).AppendLine();
        }

        File.WriteAllText(_responsePath, builder.ToString(), Utf8NoBom);
    }

    private static void TruncateResponse()
    {
        try
        {
            File.WriteAllText(_responsePath, string.Empty, Utf8NoBom);
        }
        catch (Exception exception)
        {
            Log("truncate response failed: " + exception.Message);
        }
    }

    private static string ToBase64(string value)
    {
        return Convert.ToBase64String(Utf8NoBom.GetBytes(value ?? string.Empty));
    }

    private static string SanitizeStatus(string value)
    {
        return (value ?? string.Empty).Replace('\t', '_').Replace('\r', '_').Replace('\n', '_');
    }

    private static bool IsWeaselPanelVisible()
    {
        HashSet<uint> processIds = new HashSet<uint>();
        try
        {
            foreach (Process process in Process.GetProcessesByName("WeaselServer"))
                processIds.Add((uint)process.Id);
        }
        catch
        {
            return false;
        }

        if (processIds.Count == 0)
            return false;

        bool found = false;
        EnumWindows(
            delegate(IntPtr window, IntPtr parameter)
            {
                if (!IsWindowVisible(window))
                    return true;

                uint processId;
                GetWindowThreadProcessId(window, out processId);
                if (!processIds.Contains(processId))
                    return true;

                Rect rectangle;
                if (GetWindowRect(window, out rectangle) &&
                    rectangle.Right > rectangle.Left &&
                    rectangle.Bottom > rectangle.Top)
                {
                    found = true;
                    return false;
                }
                return true;
            },
            IntPtr.Zero);
        return found;
    }

    private static void SendF24()
    {
        keybd_event(VirtualKeyF24, 0, 0, UIntPtr.Zero);
        keybd_event(VirtualKeyF24, 0, KeyEventKeyUp, UIntPtr.Zero);
    }

    private static int ReadUInt16(byte[] bytes, int position)
    {
        EnsureAvailable(bytes, position, 2);
        return bytes[position] | (bytes[position + 1] << 8);
    }

    private static void EnsureAvailable(byte[] bytes, int position, int length)
    {
        if (position < 0 || length < 0 || position + length > bytes.Length)
            throw new InvalidDataException("Invalid Sogou response packet.");
    }

    private static string WebExceptionStatus(WebException exception)
    {
        if (exception.Status == System.Net.WebExceptionStatus.Timeout)
            return "timeout";

        HttpWebResponse response = exception.Response as HttpWebResponse;
        if (response != null)
            return "http_" + (int)response.StatusCode;
        return "network:" + exception.Status;
    }

    private static int ParseInt(string value, int fallback)
    {
        int parsed;
        return int.TryParse(value, out parsed) ? parsed : fallback;
    }

    private static int Clamp(int value, int minimum, int maximum)
    {
        if (value < minimum)
            return minimum;
        if (value > maximum)
            return maximum;
        return value;
    }

    private static void WriteHeartbeat()
    {
        try
        {
            long epochSeconds = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds;
            File.WriteAllText(_heartbeatPath, epochSeconds.ToString(), Utf8NoBom);
        }
        catch
        {
        }
    }

    private static void Log(string message)
    {
        try
        {
            lock (LogLock)
            {
                File.AppendAllText(
                    _logPath,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine,
                    Utf8NoBom);
            }
        }
        catch
        {
        }
    }
}
