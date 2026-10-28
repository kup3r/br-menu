import Foundation

enum ReactSound25 {
    static let names = ["Мягкий щелчок", "Металл", "Аркада", "Бас", "Цифровой", "Стекло", "Дерево", "Лазер"]
    static func selected(_ kind: String) -> Int {
        let key = "React.sound25." + kind
        return UserDefaults.standard.object(forKey: key) == nil ? (kind == "hit" ? 1 : 0) : max(0,min(names.count-1,UserDefaults.standard.integer(forKey:key)))
    }
    static func select(_ index: Int, kind: String) { UserDefaults.standard.set(max(0,min(names.count-1,index)),forKey:"React.sound25."+kind) }
    static func wave(_ index: Int) -> Data {
        let choice = max(0,min(names.count-1,index)), rate = 22050, count = choice == 7 ? 2646 : 1764
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf:s.utf8) }
        func put<T: FixedWidthInteger>(_ v: T) { var x=v.littleEndian; withUnsafeBytes(of:&x) { data.append(contentsOf:$0) } }
        ascii("RIFF");put(UInt32(36+count*2));ascii("WAVEfmt ");put(UInt32(16));put(UInt16(1));put(UInt16(1))
        put(UInt32(rate));put(UInt32(rate*2));put(UInt16(2));put(UInt16(16));ascii("data");put(UInt32(count*2))
        var noise: UInt32 = 0x12345678
        for i in 0..<count {
            let t = Double(i)/Double(rate), envelope = exp(-(choice == 7 ? 45.0 : 85.0)*t)*min(1,t/0.001)
            noise = 1664525 &* noise &+ 1013904223
            let n = Double(noise & 65535)/32767.5-1, p = 2*Double.pi
            let value: Double
            switch choice {
            case 1: value = 0.45*sin(p*2400*t)+0.3*sin(p*4177*t)+0.15*n
            case 2: value = 0.65*(sin(p*1100*t) >= 0 ? 1 : -1)+0.15*sin(p*2200*t)
            case 3: value = 0.75*sin(p*(170*t-550*t*t))+0.15*n
            case 4: value = 0.6*sin(p*(3200*t-7000*t*t))+0.2*sin(p*900*t)
            case 5: value = 0.45*sin(p*3500*t)+0.3*sin(p*5621*t)+0.15*sin(p*7193*t)
            case 6: value = 0.45*n+0.4*sin(p*650*t)
            case 7: value = 0.6*sin(p*(1800*t-5000*t*t))+0.2*sin(p*300*t)
            default: value = 0.55*sin(p*1700*t)+0.2*sin(p*3100*t)
            }
            put(Int16(max(-32767,min(32767,value*envelope*28000))))
        }
        return data
    }
}
