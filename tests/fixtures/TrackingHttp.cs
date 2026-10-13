using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace PSAITerminalTests
{
    // 仅由隔离资源回归加载；响应由内存构造，禁止外部网络。
    public sealed class TrackingContent : HttpContent
    {
        public readonly string Mode;
        public bool Disposed;
        public TrackingStream Stream;
        public readonly TaskCompletionSource<Stream> Pending = new TaskCompletionSource<Stream>();

        public TrackingContent(string mode) { Mode = mode; }

        protected override Task<Stream> CreateContentReadStreamAsync()
        {
            if (Mode == "BodyFailure")
            {
                var failure = new TaskCompletionSource<Stream>();
                failure.SetException(new IOException("fixture-body-failure"));
                return failure.Task;
            }
            if (Mode == "Cancel") { return Pending.Task; }
            Stream = new TrackingStream(Encoding.UTF8.GetBytes(new string('x', 1024 * 1024 + 1)));
            return Task.FromResult<Stream>(Stream);
        }

        protected override Task SerializeToStreamAsync(Stream stream, TransportContext context)
        {
            throw new InvalidOperationException("资源测试必须使用 ResponseHeadersRead。");
        }

        protected override bool TryComputeLength(out long length) { length = 0; return false; }

        protected override void Dispose(bool disposing)
        {
            Disposed = true;
            base.Dispose(disposing);
        }
    }

    public sealed class TrackingStream : MemoryStream
    {
        public bool Disposed;
        public TrackingStream(byte[] bytes) : base(bytes) { }
        protected override void Dispose(bool disposing)
        {
            Disposed = true;
            base.Dispose(disposing);
        }
    }

    public sealed class TrackingHandler : HttpMessageHandler
    {
        public readonly TrackingContent Content;
        public bool Disposed;
        public TrackingHandler(string mode) { Content = new TrackingContent(mode); }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = Content });
        }
        protected override void Dispose(bool disposing)
        {
            Disposed = true;
            base.Dispose(disposing);
        }
    }

    public sealed class DelayedReader : StreamReader
    {
        public readonly TaskCompletionSource<int> Pending = new TaskCompletionSource<int>();
        public DelayedReader() : base(new MemoryStream()) { }
        public override Task<int> ReadAsync(char[] buffer, int index, int count) { return Pending.Task; }
    }
}
