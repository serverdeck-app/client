#include "mcp_idle_bridge.h"
#include <deque>
#include <iostream>
#include <future>

using namespace sd::mcp;
namespace {
void Check(bool value) { if (!value) throw std::runtime_error("idle bridge unit assertion"); }
std::string Wrap(const std::string& payload) { return Encode(Json::Object{{"kind","mcp"},{"payload",Decode(payload)}}); }
const std::string init = Wrap(R"({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"synthetic","version":"1"}}})");
const std::string initialized = Wrap(R"({"jsonrpc":"2.0","method":"notifications/initialized"})");
const std::string initializedResult = Wrap(R"({"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":false}}}})");
const std::string call = Wrap(R"({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"synthetic.mutation","arguments":{}}})");
struct Fixture {
  uint64_t now = 0;
  int connects = 0, disconnects = 0;
  bool deny = false, failSend = false;
  int64_t version = 1;
  std::vector<std::string> sent, output;
  std::deque<std::string> replies;
  IdleBridge bridge;
  Fixture() : bridge(IdleBridgePorts{
    [&] { ++connects; if (deny) throw BoundaryFailure{22}; return version; },
    [&] { ++disconnects; },
    [&](const std::string& value) { if (failSend) throw EndOfStream{}; sent.push_back(value); },
    [&](const std::string& value) { output.push_back(value); },
    [&] { if (replies.empty()) throw EndOfStream{}; auto result = replies.front(); replies.pop_front(); return result; },
    [&] { return now; }}) {}
  void Start() { bridge.Connect(); bridge.Input(init); bridge.Output(initializedResult); bridge.Input(initialized); }
  void Park() { now += IdleBridge::idleMs; Check(bridge.Park()); Check(!bridge.connected()); }
};
template<class F> void Reject(F run) { bool rejected = false; try { run(); } catch (...) { rejected = true; } Check(rejected); }
void QueueUnits() {
  BridgeOutcome eof; eof.Finish(0); eof.Finish(23); eof.Finish(22); Check(eof.code() == 0);
  BridgeOutcome failure; failure.Finish(21); failure.Finish(0); failure.Finish(23); Check(failure.code() == 21);
  BridgeFrames frames;
  for (int n = 0; n < 16; ++n) frames.Push("{}");
  Reject([&] { frames.Push("{}"); });
  Check(frames.Pop() == "{}"); frames.Push("{}"); frames.Clear(); Check(frames.empty());
  frames.Push(std::string(kFrameBytes - 1, 'x'));
  Reject([&] { frames.Push("x"); }); frames.Pop(); frames.Push("{}");
  OutputFrames output;
  std::promise<void> entered, cancelled;
  auto unblocked = cancelled.get_future().share();
  int writes = 0;
  output.Push("first"); output.Push("discard on EOF");
  auto writer = std::async(std::launch::async, [&] {
    output.Run([&](const std::string& frame) { Check(frame == "first"); ++writes; entered.set_value(); unblocked.wait(); });
  });
  entered.get_future().wait();
  // EOF can stop the queue while its writer is externally blocked. The owned
  // worker cancellation hook then interrupts that writer (synthetic IO here).
  output.Stop(); output.Push("after stop"); cancelled.set_value(); writer.get(); Check(writes == 1);
  OutputFrames idle;
  auto waiting = std::async(std::launch::async, [&] { idle.Run([](const std::string&) { Check(false); }); });
  idle.Stop(); waiting.get();
  for (const auto& item : std::vector<std::pair<int, std::string>>{{20,"APP_UNAVAILABLE\n"},{21,"PEER_REJECTED\n"},{22,"AUTH_REQUIRED\n"},{23,"MCP_PROTOCOL\n"}})
    Check(BridgeFailureMessage(item.first) == item.second);
}
void Units() {
  QueueUnits();
  { Fixture f; f.Start();
    const auto large = std::string(1100000, 'x');
    const auto candidate = [&](int id) { return Encode(Json::Object{{"kind","mcp"},{"payload",Json::Object{
      {"jsonrpc","2.0"},{"id",id},{"method","initialize"},{"params",Json::Object{
        {"protocolVersion","2025-11-25"},{"capabilities",Json::Object{}},{"clientInfo",Json::Object{{"name",large}}}}}}}}); };
    f.bridge.Input(candidate(2)); Reject([&] { f.bridge.Input(candidate(3)); }); Check(f.sent.size() == 3);
  }
  { Fixture f; f.Start();
    const auto next = Wrap(R"({"jsonrpc":"2.0","id":2,"method":"initialize","params":{}})");
    f.bridge.Input(next); f.bridge.Output(Wrap(R"({"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"INVALID_PARAMS"}})"));
    f.Park(); f.replies.push_back(initializedResult); f.bridge.Input(call); Check(f.sent[3] == init);
  }
  { Fixture f; f.Start(); f.now = 299999; Check(!f.bridge.Park()); ++f.now; Check(f.bridge.Park()); Check(f.disconnects == 1); Check(!f.bridge.Park()); }
  { Fixture f; f.Start(); f.now = 299999; f.bridge.Input(Wrap(R"({"jsonrpc":"2.0","method":"synthetic.notification"})"));
    ++f.now; Check(!f.bridge.Park()); f.now += 299999; Check(f.bridge.Park()); }
  { Fixture f; f.Start(); f.bridge.Input(call); f.now = 900000; Check(!f.bridge.Park());
    f.bridge.Output(Wrap(R"({"jsonrpc":"2.0","id":1,"result":{}})")); f.now += 299999; Check(!f.bridge.Park()); ++f.now; Check(f.bridge.Park()); }
  { Fixture f; f.Start(); f.Park(); const auto visible = f.output.size(); f.replies.push_back(initializedResult); f.bridge.Input(call);
    Check(f.connects == 2); Check(f.output.size() == visible); Check(f.sent.size() == 5);
    Check(f.sent[2] == init && f.sent[3] == initialized && f.sent[4] == call);
    f.bridge.Output(Wrap(R"({"jsonrpc":"2.0","id":1,"result":{}})")); f.Park();
    // Duplicate IDs remain invalid across fresh server sessions, with no wake.
    f.bridge.Input(call); Check(f.connects == 2); Check(Decode(f.output.back()).at("error").at("code").integer() == -32600);
  }
  { Fixture f; f.Start(); f.Park(); f.version = 2; Reject([&] { f.bridge.Input(call); }); Check(f.sent.size() == 2); }
  { Fixture f; f.Start(); f.Park(); f.deny = true; Reject([&] { f.bridge.Input(call); }); Check(f.sent.size() == 2); }
  { Fixture f; f.Start(); f.Park(); f.replies.push_back(Wrap(R"({"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"different","capabilities":{}}})"));
    Reject([&] { f.bridge.Input(call); }); Check(f.sent.size() == 3); }
  { Fixture f; f.Start(); f.Park(); f.replies.push_back(initializedResult); f.failSend = true;
    Reject([&] { f.bridge.Input(call); }); Check(f.connects == 2); Check(f.sent.size() == 2); }
  { Fixture f; f.Start(); f.Park(); Reject([&] { f.bridge.Input(call); }); Check(f.sent.size() == 3); }
  { Fixture f; f.bridge.Connect(); f.now = 300000; Reject([&] { f.bridge.Park(); }); }
  { Fixture f; f.Start(); f.bridge.Input(call); f.now = 300000; Check(!f.bridge.Park());
    f.bridge.Output(Wrap(R"({"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"INVALID_PARAMS"}})")); f.Park(); }
  // Integer and floating representations of an ID identify the same request.
  { Fixture f; f.Start(); f.bridge.Input(Wrap(R"({"jsonrpc":"2.0","id":1.0,"method":"ping"})"));
    f.bridge.Input(Wrap(R"({"jsonrpc":"2.0","id":1,"method":"ping"})")); Check(f.sent.size() == 3); }
  { Fixture f; f.Start(); for (int n = 1; n <= 16; ++n) f.bridge.Input(Wrap("{\"jsonrpc\":\"2.0\",\"id\":" + std::to_string(n) + ",\"method\":\"ping\"}"));
    Reject([&] { f.bridge.Input(Wrap(R"({"jsonrpc":"2.0","id":17,"method":"ping"})")); }); }
}
}
int main() {
  try { Units(); std::cout << "Idle bridge synthetic units passed; no processes, pipes, DPAPI or product launched.\n"; return 0; }
  catch (...) { std::cerr << "Idle bridge unit failure\n"; return 1; }
}
