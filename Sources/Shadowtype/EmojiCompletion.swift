// EmojiCompletion — built-in `:shortcode:` -> emoji lookup (PRD FR-EM-1, FREE).
// Pure logic, fully self-contained, no network. The coordinator detects a shortcode being typed
// (isTrigger), shows the top match as a ghost, and Tab inserts the emoji (counts as 0 words).
import Foundation

final class EmojiCompletion {
    // Built-in shortcode -> emoji table (a few hundred common GitHub/Slack-style codes).
    // Insertion order doubles as a relevance/popularity bias for `matches`.
    private let table: [(shortcode: String, emoji: String)] = [
        ("smile", "😄"), ("smiley", "😃"), ("grin", "😁"), ("laughing", "😆"), ("sweat_smile", "😅"),
        ("joy", "😂"), ("rofl", "🤣"), ("relaxed", "☺️"), ("blush", "😊"), ("innocent", "😇"),
        ("slightly_smiling_face", "🙂"), ("upside_down_face", "🙃"), ("wink", "😉"), ("relieved", "😌"),
        ("heart_eyes", "😍"), ("smiling_face_with_three_hearts", "🥰"), ("kissing_heart", "😘"),
        ("kissing", "😗"), ("kissing_closed_eyes", "😚"), ("kissing_smiling_eyes", "😙"),
        ("yum", "😋"), ("stuck_out_tongue", "😛"), ("stuck_out_tongue_winking_eye", "😜"),
        ("zany_face", "🤪"), ("stuck_out_tongue_closed_eyes", "😝"), ("money_mouth_face", "🤑"),
        ("hugs", "🤗"), ("hand_over_mouth", "🤭"), ("shushing_face", "🤫"), ("thinking", "🤔"),
        ("zipper_mouth_face", "🤐"), ("raised_eyebrow", "🤨"), ("neutral_face", "😐"),
        ("expressionless", "😑"), ("no_mouth", "😶"), ("smirk", "😏"), ("unamused", "😒"),
        ("roll_eyes", "🙄"), ("grimacing", "😬"), ("lying_face", "🤥"), ("relieved_face", "😌"),
        ("pensive", "😔"), ("sleepy", "😪"), ("drooling_face", "🤤"), ("sleeping", "😴"),
        ("mask", "😷"), ("face_with_thermometer", "🤒"), ("face_with_head_bandage", "🤕"),
        ("nauseated_face", "🤢"), ("vomiting_face", "🤮"), ("sneezing_face", "🤧"),
        ("hot_face", "🥵"), ("cold_face", "🥶"), ("woozy_face", "🥴"), ("dizzy_face", "😵"),
        ("exploding_head", "🤯"), ("cowboy_hat_face", "🤠"), ("partying_face", "🥳"),
        ("sunglasses", "😎"), ("nerd_face", "🤓"), ("monocle_face", "🧐"), ("confused", "😕"),
        ("worried", "😟"), ("slightly_frowning_face", "🙁"), ("frowning_face", "☹️"),
        ("open_mouth", "😮"), ("hushed", "😯"), ("astonished", "😲"), ("flushed", "😳"),
        ("pleading_face", "🥺"), ("frowning", "😦"), ("anguished", "😧"), ("fearful", "😨"),
        ("cold_sweat", "😰"), ("disappointed_relieved", "😥"), ("cry", "😢"), ("sob", "😭"),
        ("scream", "😱"), ("confounded", "😖"), ("persevere", "😣"), ("disappointed", "😞"),
        ("sweat", "😓"), ("weary", "😩"), ("tired_face", "😫"), ("yawning_face", "🥱"),
        ("triumph", "😤"), ("rage", "😡"), ("angry", "😠"), ("cursing_face", "🤬"),
        ("smiling_imp", "😈"), ("imp", "👿"), ("skull", "💀"), ("skull_and_crossbones", "☠️"),
        ("poop", "💩"), ("clown_face", "🤡"), ("japanese_ogre", "👹"), ("ghost", "👻"),
        ("alien", "👽"), ("space_invader", "👾"), ("robot", "🤖"), ("smiley_cat", "😺"),
        ("smile_cat", "😸"), ("joy_cat", "😹"), ("heart_eyes_cat", "😻"), ("pouting_cat", "😾"),
        ("crying_cat_face", "😿"), ("see_no_evil", "🙈"), ("hear_no_evil", "🙉"),
        ("speak_no_evil", "🙊"), ("kiss", "💋"), ("love_letter", "💌"), ("cupid", "💘"),
        ("gift_heart", "💝"), ("sparkling_heart", "💖"), ("heartpulse", "💗"), ("heartbeat", "💓"),
        ("revolving_hearts", "💞"), ("two_hearts", "💕"), ("heart_decoration", "💟"),
        ("broken_heart", "💔"), ("heart", "❤️"), ("orange_heart", "🧡"), ("yellow_heart", "💛"),
        ("green_heart", "💚"), ("blue_heart", "💙"), ("purple_heart", "💜"), ("black_heart", "🖤"),
        ("brown_heart", "🤎"), ("white_heart", "🤍"), ("100", "💯"), ("anger", "💢"),
        ("boom", "💥"), ("dizzy", "💫"), ("sweat_drops", "💦"), ("dash", "💨"),
        ("hole", "🕳️"), ("bomb", "💣"), ("speech_balloon", "💬"), ("thought_balloon", "💭"),
        ("zzz", "💤"), ("wave", "👋"), ("raised_back_of_hand", "🤚"), ("raised_hand", "✋"),
        ("vulcan_salute", "🖖"), ("ok_hand", "👌"), ("pinching_hand", "🤏"), ("v", "✌️"),
        ("crossed_fingers", "🤞"), ("love_you_gesture", "🤟"), ("metal", "🤘"), ("call_me_hand", "🤙"),
        ("point_left", "👈"), ("point_right", "👉"), ("point_up_2", "👆"), ("middle_finger", "🖕"),
        ("point_down", "👇"), ("point_up", "☝️"), ("+1", "👍"), ("thumbsup", "👍"),
        ("-1", "👎"), ("thumbsdown", "👎"), ("fist", "✊"), ("facepunch", "👊"),
        ("left_facing_fist", "🤛"), ("right_facing_fist", "🤜"), ("clap", "👏"),
        ("raised_hands", "🙌"), ("open_hands", "👐"), ("palms_up_together", "🤲"),
        ("handshake", "🤝"), ("pray", "🙏"), ("writing_hand", "✍️"), ("nail_care", "💅"),
        ("selfie", "🤳"), ("muscle", "💪"), ("mechanical_arm", "🦾"), ("eyes", "👀"),
        ("eye", "👁️"), ("brain", "🧠"), ("tongue", "👅"), ("ear", "👂"), ("nose", "👃"),
        ("baby", "👶"), ("boy", "👦"), ("girl", "👧"), ("man", "👨"), ("woman", "👩"),
        ("older_man", "👴"), ("older_woman", "👵"), ("person", "🧑"), ("cop", "👮"),
        ("guard", "💂"), ("construction_worker", "👷"), ("prince", "🤴"), ("princess", "👸"),
        ("angel", "👼"), ("santa", "🎅"), ("mrs_claus", "🤶"), ("superhero", "🦸"),
        ("supervillain", "🦹"), ("mage", "🧙"), ("fairy", "🧚"), ("vampire", "🧛"),
        ("merperson", "🧜"), ("elf", "🧝"), ("genie", "🧞"), ("zombie", "🧟"),
        ("walking", "🚶"), ("running", "🏃"), ("dancer", "💃"), ("man_dancing", "🕺"),
        ("dog", "🐶"), ("cat", "🐱"), ("mouse", "🐭"), ("hamster", "🐹"), ("rabbit", "🐰"),
        ("fox_face", "🦊"), ("bear", "🐻"), ("panda_face", "🐼"), ("koala", "🐨"),
        ("tiger", "🐯"), ("lion", "🦁"), ("cow", "🐮"), ("pig", "🐷"), ("frog", "🐸"),
        ("monkey_face", "🐵"), ("chicken", "🐔"), ("penguin", "🐧"), ("bird", "🐦"),
        ("baby_chick", "🐤"), ("duck", "🦆"), ("eagle", "🦅"), ("owl", "🦉"), ("bat", "🦇"),
        ("wolf", "🐺"), ("boar", "🐗"), ("horse", "🐴"), ("unicorn", "🦄"), ("bee", "🐝"),
        ("bug", "🐛"), ("butterfly", "🦋"), ("snail", "🐌"), ("beetle", "🪲"), ("ant", "🐜"),
        ("spider", "🕷️"), ("scorpion", "🦂"), ("turtle", "🐢"), ("snake", "🐍"),
        ("lizard", "🦎"), ("octopus", "🐙"), ("squid", "🦑"), ("shrimp", "🦐"),
        ("crab", "🦀"), ("blowfish", "🐡"), ("tropical_fish", "🐠"), ("fish", "🐟"),
        ("dolphin", "🐬"), ("whale", "🐳"), ("shark", "🦈"), ("crocodile", "🐊"),
        ("tiger2", "🐅"), ("leopard", "🐆"), ("zebra", "🦓"), ("gorilla", "🦍"),
        ("elephant", "🐘"), ("hippopotamus", "🦛"), ("rhinoceros", "🦏"), ("camel", "🐫"),
        ("giraffe", "🦒"), ("kangaroo", "🦘"), ("sheep", "🐑"), ("goat", "🐐"),
        ("deer", "🦌"), ("dragon", "🐉"), ("dragon_face", "🐲"), ("cactus", "🌵"),
        ("christmas_tree", "🎄"), ("evergreen_tree", "🌲"), ("deciduous_tree", "🌳"),
        ("palm_tree", "🌴"), ("seedling", "🌱"), ("herb", "🌿"), ("four_leaf_clover", "🍀"),
        ("bamboo", "🎍"), ("tulip", "🌷"), ("rose", "🌹"), ("wilted_flower", "🥀"),
        ("hibiscus", "🌺"), ("sunflower", "🌻"), ("blossom", "🌼"), ("cherry_blossom", "🌸"),
        ("bouquet", "💐"), ("mushroom", "🍄"), ("chestnut", "🌰"), ("earth_africa", "🌍"),
        ("earth_americas", "🌎"), ("earth_asia", "🌏"), ("new_moon", "🌑"),
        ("full_moon", "🌕"), ("crescent_moon", "🌙"), ("star", "⭐"), ("star2", "🌟"),
        ("sparkles", "✨"), ("zap", "⚡"), ("fire", "🔥"), ("sunny", "☀️"),
        ("partly_sunny", "⛅"), ("cloud", "☁️"), ("rainbow", "🌈"), ("umbrella", "☔"),
        ("snowflake", "❄️"), ("snowman", "⛄"), ("droplet", "💧"), ("ocean", "🌊"),
        ("apple", "🍎"), ("green_apple", "🍏"), ("pear", "🍐"), ("tangerine", "🍊"),
        ("lemon", "🍋"), ("banana", "🍌"), ("watermelon", "🍉"), ("grapes", "🍇"),
        ("strawberry", "🍓"), ("melon", "🍈"), ("cherries", "🍒"), ("peach", "🍑"),
        ("pineapple", "🍍"), ("coconut", "🥥"), ("kiwi_fruit", "🥝"), ("tomato", "🍅"),
        ("avocado", "🥑"), ("eggplant", "🍆"), ("potato", "🥔"), ("carrot", "🥕"),
        ("corn", "🌽"), ("hot_pepper", "🌶️"), ("cucumber", "🥒"), ("broccoli", "🥦"),
        ("bread", "🍞"), ("croissant", "🥐"), ("cheese", "🧀"), ("egg", "🥚"),
        ("bacon", "🥓"), ("pancakes", "🥞"), ("hamburger", "🍔"), ("fries", "🍟"),
        ("pizza", "🍕"), ("hotdog", "🌭"), ("taco", "🌮"), ("burrito", "🌯"),
        ("ramen", "🍜"), ("spaghetti", "🍝"), ("sushi", "🍣"), ("rice", "🍚"),
        ("curry", "🍛"), ("bento", "🍱"), ("oden", "🍢"), ("dango", "🍡"),
        ("icecream", "🍦"), ("shaved_ice", "🍧"), ("ice_cream", "🍨"), ("doughnut", "🍩"),
        ("cookie", "🍪"), ("birthday", "🎂"), ("cake", "🍰"), ("cupcake", "🧁"),
        ("pie", "🥧"), ("chocolate_bar", "🍫"), ("candy", "🍬"), ("lollipop", "🍭"),
        ("honey_pot", "🍯"), ("coffee", "☕"), ("tea", "🍵"), ("sake", "🍶"),
        ("champagne", "🍾"), ("wine_glass", "🍷"), ("cocktail", "🍸"), ("tropical_drink", "🍹"),
        ("beer", "🍺"), ("beers", "🍻"), ("clinking_glasses", "🥂"), ("tumbler_glass", "🥃"),
        ("soccer", "⚽"), ("basketball", "🏀"), ("football", "🏈"), ("baseball", "⚾"),
        ("tennis", "🎾"), ("volleyball", "🏐"), ("rugby_football", "🏉"), ("8ball", "🎱"),
        ("golf", "⛳"), ("ping_pong", "🏓"), ("badminton", "🏸"), ("dart", "🎯"),
        ("bowling", "🎳"), ("video_game", "🎮"), ("game_die", "🎲"), ("trophy", "🏆"),
        ("medal_sports", "🏅"), ("first_place_medal", "🥇"), ("second_place_medal", "🥈"),
        ("third_place_medal", "🥉"), ("rocket", "🚀"), ("airplane", "✈️"), ("car", "🚗"),
        ("taxi", "🚕"), ("bus", "🚌"), ("ambulance", "🚑"), ("fire_engine", "🚒"),
        ("police_car", "🚓"), ("truck", "🚚"), ("tractor", "🚜"), ("bike", "🚲"),
        ("motorcycle", "🏍️"), ("train", "🚆"), ("metro", "🚇"), ("ship", "🚢"),
        ("anchor", "⚓"), ("helicopter", "🚁"), ("satellite", "🛰️"), ("traffic_light", "🚦"),
        ("construction", "🚧"), ("computer", "💻"), ("desktop_computer", "🖥️"),
        ("keyboard", "⌨️"), ("printer", "🖨️"), ("iphone", "📱"), ("telephone", "☎️"),
        ("battery", "🔋"), ("electric_plug", "🔌"), ("bulb", "💡"), ("flashlight", "🔦"),
        ("candle", "🕯️"), ("camera", "📷"), ("video_camera", "📹"), ("movie_camera", "🎥"),
        ("tv", "📺"), ("radio", "📻"), ("microphone", "🎤"), ("headphones", "🎧"),
        ("musical_note", "🎵"), ("notes", "🎶"), ("guitar", "🎸"), ("piano", "🎹"),
        ("drum", "🥁"), ("trumpet", "🎺"), ("violin", "🎻"), ("saxophone", "🎷"),
        ("book", "📖"), ("books", "📚"), ("notebook", "📓"), ("ledger", "📒"),
        ("page_facing_up", "📄"), ("newspaper", "📰"), ("bookmark", "🔖"), ("label", "🏷️"),
        ("moneybag", "💰"), ("dollar", "💵"), ("yen", "💴"), ("euro", "💶"), ("pound", "💷"),
        ("credit_card", "💳"), ("gem", "💎"), ("hammer", "🔨"), ("axe", "🪓"),
        ("wrench", "🔧"), ("nut_and_bolt", "🔩"), ("gear", "⚙️"), ("link", "🔗"),
        ("paperclip", "📎"), ("scissors", "✂️"), ("lock", "🔒"), ("unlock", "🔓"),
        ("key", "🔑"), ("mag", "🔍"), ("calendar", "📅"), ("clipboard", "📋"),
        ("pushpin", "📌"), ("memo", "📝"), ("pencil2", "✏️"), ("pen", "🖊️"),
        ("email", "📧"), ("envelope", "✉️"), ("inbox_tray", "📥"), ("outbox_tray", "📤"),
        ("package", "📦"), ("mailbox", "📫"), ("bell", "🔔"), ("no_bell", "🔕"),
        ("loudspeaker", "📢"), ("mega", "📣"), ("hourglass", "⌛"), ("watch", "⌚"),
        ("alarm_clock", "⏰"), ("stopwatch", "⏱️"), ("warning", "⚠️"), ("no_entry", "⛔"),
        ("white_check_mark", "✅"), ("heavy_check_mark", "✔️"), ("x", "❌"),
        ("negative_squared_cross_mark", "❎"), ("question", "❓"), ("exclamation", "❗"),
        ("bangbang", "‼️"), ("interrobang", "⁉️"), ("recycle", "♻️"), ("checkered_flag", "🏁"),
        ("triangular_flag_on_post", "🚩"), ("crossed_flags", "🎌"), ("black_flag", "🏴"),
        ("white_flag", "🏳️"), ("rainbow_flag", "🏳️‍🌈"), ("tada", "🎉"), ("confetti_ball", "🎊"),
        ("balloon", "🎈"), ("gift", "🎁"), ("ribbon", "🎀"), ("jack_o_lantern", "🎃"),
        ("fireworks", "🎆"), ("sparkler", "🎇"), ("crown", "👑"), ("ring", "💍"),
        ("rotating_light", "🚨"), ("art", "🎨"), ("clapper", "🎬"), ("musical_score", "🎼"),
        ("dollar_banknote", "💵"), ("chart_with_upwards_trend", "📈"),
        ("chart_with_downwards_trend", "📉"), ("bar_chart", "📊"), ("date", "📆"),
        ("calendar_spiral", "🗓️"), ("file_folder", "📁"), ("open_file_folder", "📂"),
        ("wastebasket", "🗑️"), ("hospital", "🏥"), ("house", "🏠"), ("office", "🏢"),
        ("school", "🏫"), ("bank", "🏦"), ("hotel", "🏨"), ("church", "⛪"),
        ("statue_of_liberty", "🗽"), ("tokyo_tower", "🗼"), ("mount_fuji", "🗻"),
        ("volcano", "🌋"), ("camping", "🏕️"), ("beach_umbrella", "🏖️"), ("desert", "🏜️"),
        ("national_park", "🏞️"), ("stadium", "🏟️"), ("ferris_wheel", "🎡"),
        ("roller_coaster", "🎢"), ("circus_tent", "🎪"), ("performing_arts", "🎭"),
        ("ticket", "🎫"), ("dancers", "👯"), ("dizzy_face2", "😵‍💫"),
    ]

    // Fast lookup for exact code -> emoji.
    private let byCode: [String: String]

    init() {
        var map: [String: String] = [:]
        map.reserveCapacity(table.count)
        for entry in table { map[entry.shortcode] = entry.emoji }
        byCode = map
    }

    // True when `prefix` ends with `:` followed by one or more shortcode chars ([a-z0-9_+-]).
    // i.e. a shortcode is actively being typed and not yet closed by a trailing `:`.
    func isTrigger(prefix: String) -> Bool {
        return currentQuery(prefix: prefix) != nil
    }

    // The partial shortcode after the last unterminated `:`, or nil. Lowercased for matching.
    // Returns nil for an empty query (`...:`) — there's nothing to match yet.
    func currentQuery(prefix: String) -> String? {
        guard let colon = prefix.lastIndex(of: ":") else { return nil }
        let after = prefix[prefix.index(after: colon)...]
        guard !after.isEmpty else { return nil }
        for ch in after where !Self.isShortcodeChar(ch) { return nil }
        return after.lowercased()
    }

    // Shortcodes whose code contains the partial query, ranked: exact match, then prefix matches,
    // then substring matches; ties broken by table (popularity) order. Capped at `limit`.
    func matches(prefix: String, limit: Int) -> [(shortcode: String, emoji: String)] {
        guard limit > 0, let query = currentQuery(prefix: prefix) else { return [] }
        var out: [(shortcode: String, emoji: String)] = []
        var seen = Set<String>()
        // Pass 1: exact code.
        if let emoji = byCode[query], seen.insert(query).inserted {
            out.append((query, emoji))
        }
        // Pass 2: prefix matches. Pass 3: substring matches. Preserve table order within each pass.
        for prefixPass in [true, false] {
            for entry in table where out.count < limit {
                guard !seen.contains(entry.shortcode) else { continue }
                let hit = prefixPass ? entry.shortcode.hasPrefix(query)
                                     : entry.shortcode.contains(query)
                if hit {
                    out.append(entry)
                    seen.insert(entry.shortcode)
                }
            }
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    private static func isShortcodeChar(_ ch: Character) -> Bool {
        return ch.isLetter || ch.isNumber || ch == "_" || ch == "+" || ch == "-"
    }
}
