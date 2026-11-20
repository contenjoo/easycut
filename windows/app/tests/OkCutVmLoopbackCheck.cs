using NAudio.CoreAudioApi;
using NAudio.Wave;

using var devices = new MMDeviceEnumerator();
using var endpoint = devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
using var capture = new WasapiLoopbackCapture(endpoint);
using var writer = new WaveFileWriter(args[0], capture.WaveFormat);
using var finished = new ManualResetEventSlim();
Exception? problem = null;
capture.DataAvailable += (_, e) => writer.Write(e.Buffer, 0, e.BytesRecorded);
capture.RecordingStopped += (_, e) => { problem = e.Exception; finished.Set(); };
Console.WriteLine($"Default Windows endpoint: {endpoint.FriendlyName}, format: {capture.WaveFormat}, muted: {endpoint.AudioEndpointVolume.Mute}");
capture.StartRecording();
Thread.Sleep(2600);
capture.StopRecording();
if (!finished.Wait(TimeSpan.FromSeconds(6))) throw new TimeoutException("WASAPI did not stop");
if (problem is not null) throw problem;
