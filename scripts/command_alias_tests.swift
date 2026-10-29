import Foundation
@main
struct CommandTests {
    static func main() {
        let rules = "/cf=/cuff; /u=/uncuff"
        assert(ReactCommandAliases.expand("/cf 17", rules: rules) == "/cuff 17")
        assert(ReactCommandAliases.expand("/CF 17 Name_Case", rules: rules) == "/cuff 17 Name_Case")
        assert(ReactCommandAliases.expand("/cf", rules: rules) == "/cuff")
        assert(ReactCommandAliases.expand("/cfx 17", rules: rules) == "/cfx 17")
        assert(ReactCommandAliases.expand("/unknown /cf 17", rules: rules) == "/unknown /cf 17")
        assert(ReactCommandAliases.expand("hello /cf", rules: rules) == "hello /cf")
        assert(ReactCommandAliases.expand("/cf 17", rules: "/cf=/bad command") == "/cf 17")
        assert(ReactCommandAliases.expand("/cf 17", rules: "/cf=/u; /u=/uncuff") == "/u 17")
        print("Command alias tests passed")
    }
}
