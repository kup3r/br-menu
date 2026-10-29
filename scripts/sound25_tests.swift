import Foundation
@main struct Tests {
 static func main() {
  var waves = Set<Data>()
  for i in ReactSound25.names.indices {
   let data = ReactSound25.wave(i)
   assert(data.count>44 && String(data:data.prefix(4),encoding:.ascii)=="RIFF")
   assert(String(data:data.subdata(in:8..<12),encoding:.ascii)=="WAVE")
   let payload = Int(data[40]) | Int(data[41])<<8 | Int(data[42])<<16 | Int(data[43])<<24
   assert(payload == data.count-44 && payload/2<=4410)
   assert(waves.insert(data).inserted,"duplicate sound")
   assert(data == ReactSound25.wave(i),"unstable generator")
  }
  assert(ReactSound25.wave(-1)==ReactSound25.wave(0))
  assert(ReactSound25.wave(100)==ReactSound25.wave(7))
  print("Eight distinct deterministic bounded PCM WAV presets passed")
 }
}
