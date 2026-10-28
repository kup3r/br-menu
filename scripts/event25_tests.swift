import Foundation
@main struct Tests {
 static func main() {
  let good = "{FF0000}[МП] Администратор Test_Name начал набор на мероприятие! /gevent"
  assert(ReactEvent25.announcement(good))
  for bad in ["Player[4]: Администратор начал набор /gevent", "[МП] Мероприятие завершено /gevent", "[МП] Начат набор /geventual", "/gevent", "[МП] Начат набор /gevent_1"] { assert(!ReactEvent25.announcement(bad), bad) }
  var policy = ReactEvent25()
  assert(!policy.consume(good,now:100,received:100,enabled:false,foreground:true,connected:true))
  assert(!policy.consume(good,now:100,received:97,enabled:true,foreground:true,connected:true))
  assert(!policy.consume(good,now:100,received:100,enabled:true,foreground:false,connected:true))
  assert(!policy.consume(good,now:100,received:100,enabled:true,foreground:true,connected:false))
  assert(policy.consume(good,now:100,received:100,enabled:true,foreground:true,connected:true))
  assert(!policy.consume(good,now:111,received:111,enabled:true,foreground:true,connected:true))
  assert(!policy.consume("[МП] Начат набор 2 /gevent",now:105,received:105,enabled:true,foreground:true,connected:true))
  assert(policy.consume("[МП] Начат набор 2 /gevent",now:111,received:111,enabled:true,foreground:true,connected:true))
  print("Auto-event filtering, stale/background/disconnected rejection, deduplication and cooldown passed")
 }
}
