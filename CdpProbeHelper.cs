using System;
using System.IO;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: CdpProbeHelper.exe <port> <timeoutMilliseconds>");
            return 64;
        }

        int port;
        int timeoutMilliseconds;
        if (!int.TryParse(args[0], out port) || !int.TryParse(args[1], out timeoutMilliseconds))
        {
            Console.Error.WriteLine("Invalid arguments.");
            return 64;
        }

        try
        {
            return RunAsync(port, timeoutMilliseconds).GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.GetBaseException().Message);
            return 2;
        }
    }

    private static async Task<int> RunAsync(int port, int timeoutMilliseconds)
    {
        string json;
        using (var client = new WebClient())
        {
            client.Encoding = Encoding.UTF8;
            json = client.DownloadString("http://127.0.0.1:" + port + "/json/list");
        }

        Match match = Regex.Match(json, "\"webSocketDebuggerUrl\"\\s*:\\s*\"([^\"]+)\"");
        if (!match.Success)
        {
            Console.Error.WriteLine("No inspectable page target was found.");
            return 3;
        }

        string webSocketUrl = match.Groups[1].Value.Replace("\\/", "/");
        using (var socket = new ClientWebSocket())
        using (var timeout = new CancellationTokenSource(timeoutMilliseconds))
        {
            await socket.ConnectAsync(new Uri(webSocketUrl), timeout.Token).ConfigureAwait(false);

            const string command = "{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1+1\",\"returnByValue\":true}}";
            byte[] commandBytes = Encoding.UTF8.GetBytes(command);
            await socket.SendAsync(
                new ArraySegment<byte>(commandBytes),
                WebSocketMessageType.Text,
                true,
                timeout.Token).ConfigureAwait(false);

            var buffer = new byte[8192];
            var response = new StringBuilder();
            while (true)
            {
                WebSocketReceiveResult receive = await socket.ReceiveAsync(
                    new ArraySegment<byte>(buffer),
                    timeout.Token).ConfigureAwait(false);

                if (receive.MessageType == WebSocketMessageType.Close)
                {
                    Console.Error.WriteLine("Chrome closed the CDP WebSocket.");
                    return 4;
                }

                response.Append(Encoding.UTF8.GetString(buffer, 0, receive.Count));
                if (!receive.EndOfMessage)
                {
                    continue;
                }

                string text = response.ToString();
                if (text.IndexOf("\"id\":1", StringComparison.Ordinal) >= 0)
                {
                    if (text.IndexOf("\"value\":2", StringComparison.Ordinal) >= 0)
                    {
                        Console.WriteLine("OK");
                        return 0;
                    }

                    Console.Error.WriteLine("CDP response did not contain the expected value: " + text);
                    return 5;
                }

                response.Clear();
            }
        }
    }
}