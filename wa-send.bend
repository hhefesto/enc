import Base

# wa-send: a WhatsApp message through the Brave that is already logged in to
# web.whatsapp.com, by xdotool (the user, 11-07: "Your Brave + xdotool, as a
# small send command").  No linked device, nothing else holds the account.
#
#   wa-send draft [--dry-run] PHONE TEXT...   opens the chat with TEXT in its
#                                             box, takes a screenshot, sends nothing
#   wa-send send WINDOW                       presses Enter, takes a screenshot
#
# Two steps on purpose: the window's title never names the chat, so somebody
# must see the draft's screenshot (the chat's name, the text) before `send`.
# Every key goes only to a window that was just seen active and titled WhatsApp
# (the law `draft_guarded`); a moved focus stops the command with exit 3.
#
# PHONE: 10 digits is a Mexican mobile (521 + the digits: 52 + the digits answers
# "isn't on WhatsApp", seen 11-06); +52 and 10 digits, the same; any other +DIGITS
# is taken as it is.

# The number and the URL

def all.digits(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{h, t}:
      Bool.and(Char.is_digit(h), all.digits(t))

def has.len(+s: String, +lo: Nat, +hi: Nat) -> Bool:
  Bool.and(Nat.is_ge(String.length(s), lo), Nat.is_le(String.length(s), hi))

def some.if(ok: Bool, +v: String) -> Maybe<&2, String>:
  match ok:
    case True{}:
      Some{v}
    case False{}:
      None{}

def phone.intl(+d: String) -> Maybe<&2, String>:
  some.if(Bool.and(all.digits(d), has.len(d, 8n, 15n)),
    Bool.pick(String, Bool.and(String.starts_with(d, "52"), Nat.is_eq(String.length(d), 12n)),
      "521" ++ String.drop(d, 2n), d))

def phone.norm(+s: String) -> Maybe<&2, String>:
  Bool.pick(Maybe<&2, String>, String.starts_with(s, "+"),
    phone.intl(String.drop(s, 1n)),
    some.if(Bool.and(all.digits(s), Nat.is_eq(String.length(s), 10n)), "521" ++ s))

def in.range(+c: U32, +lo: U32, +hi: U32) -> Bool:
  Bool.and(U32.is_ge(c, lo), U32.is_le(c, hi))

# what encodeURIComponent leaves alone: letters, digits, - _ . ! ~ * ' ( )
def url.keep(+c: U32) -> Bool:
  Bool.or(in.range(c, 48, 57), Bool.or(in.range(c, 65, 90), Bool.or(in.range(c, 97, 122),
    Bool.or(U32.is_eq(c, 45), Bool.or(U32.is_eq(c, 95), Bool.or(U32.is_eq(c, 46), Bool.or(U32.is_eq(c, 33),
    Bool.or(U32.is_eq(c, 126), Bool.or(U32.is_eq(c, 42), Bool.or(U32.is_eq(c, 39), in.range(c, 40, 41)))))))))))

def hex.digit(+n: U32) -> Char:
  Char.from_u32(U32.add(n, Bool.pick(U32, U32.is_lt(n, 10), 48, 55)))

def url.byte(+b: U32) -> String:
  "%" ++ Char.show(hex.digit(U32.div(b, 16))) ++ Char.show(hex.digit(U32.mod(b, 16)))

def tail.byte(+c: U32) -> String:
  url.byte(U32.add(128, U32.mod(c, 64)))

# a code point as UTF-8, each byte %XX
def url.utf8(+c: U32) -> String:
  Bool.pick(String, U32.is_lt(c, 128), url.byte(c),
    Bool.pick(String, U32.is_lt(c, 2048), url.byte(U32.add(192, U32.div(c, 64))) ++ tail.byte(c),
      Bool.pick(String, U32.is_lt(c, 65536), url.byte(U32.add(224, U32.div(c, 4096))) ++ tail.byte(U32.div(c, 64)) ++ tail.byte(c),
        url.byte(U32.add(240, U32.div(c, 262144))) ++ tail.byte(U32.div(c, 4096)) ++ tail.byte(U32.div(c, 64)) ++ tail.byte(c))))

def url.char(+h: Char, +c: U32) -> String:
  Bool.pick(String, url.keep(c), Char.show(h), url.utf8(c))

def url.text(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+h, t}:
      url.char(h, Char.to_u32(h)) ++ url.text(t)

def send.url(phone: String, text: String) -> String:
  "https://web.whatsapp.com/send?phone=" ++ phone ++ "&text=" ++ url.text(text)

# What the keyboard does, as data

type Act is Data:
  ACheck{}
  AKey{key: String}
  AType{text: String}
  AWait{ms: U32}

# the address bar, the URL, Enter: the page opens with the text in its box.  This
# Enter goes to the address bar; the message's is `send`'s.
def draft.acts(url: String) -> List<&2, Act>:
  [ACheck{}, AKey{"ctrl+l"}, AWait{400}, ACheck{}, AType{url}, AWait{300}, ACheck{}, AKey{"Return"}]

def send.acts() -> List<&2, Act>:
  [ACheck{}, AKey{"Return"}]

# every key right after a check, with no wait between them
def guarded.go(acts: List<&2, Act>, ok: Bool) -> Bool:
  match acts:
    case Nil{}:
      True{}
    case ACheck{} <> r:
      guarded.go(r, True{})
    case AKey{_} <> r:
      Bool.and(ok, guarded.go(r, False{}))
    case AType{_} <> r:
      Bool.and(ok, guarded.go(r, False{}))
    case AWait{_} <> r:
      guarded.go(r, False{})

def guarded(acts: List<&2, Act>) -> Bool:
  guarded.go(acts, False{})

# how many Enters
def returns.add(hit: Bool, n: Nat) -> Nat:
  match hit:
    case True{}:
      1n+n
    case False{}:
      n

def returns(acts: List<&2, Act>) -> Nat:
  match acts:
    case Nil{}:
      0n
    case AKey{k} <> r:
      returns.add(String.eq(k, "Return"), returns(r))
    case _ <> r:
      returns(r)

# The laws, checked by the build

law draft_guarded:
  for url: String
  {guarded(draft.acts(url)) == True{} : Bool}

def draft_guarded(url):
  {==}

law send_guarded:
  {guarded(send.acts()) == True{} : Bool}

def send_guarded():
  {==}

law draft_one_enter:
  for url: String
  {returns(draft.acts(url)) == 1n : Nat}

def draft_one_enter(url):
  {==}

law send_one_enter:
  {returns(send.acts()) == 1n : Nat}

def send_one_enter():
  {==}

law her_mobile:
  {phone.norm("4421699811") == Some{"5214421699811"} : Maybe<&2, String>}

def her_mobile():
  {==}

law her_mobile_plus:
  {phone.norm("+524421699811") == Some{"5214421699811"} : Maybe<&2, String>}

def her_mobile_plus():
  {==}

law no_short_number:
  {phone.norm("442169") == None{} : Maybe<&2, String>}

def no_short_number():
  {==}

# the URL that opened her chat on 11-06, byte for byte
law the_url_that_worked:
  {send.url("5214421699811", "Prueba de envío automático desde mi compu (mugen). Puedes ignorarlo.") ==
    "https://web.whatsapp.com/send?phone=5214421699811&text=Prueba%20de%20env%C3%ADo%20autom%C3%A1tico%20desde%20mi%20compu%20(mugen).%20Puedes%20ignorarlo." : String}

def the_url_that_worked():
  {==}

# The machine

def got(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> U32 & String:
  match r:
    case Done{(code, (out, err))}:
      (code, out)
    case Fail{(code, msg)}:
      (127, msg)

def cmd(prog: String, args: List<String>) -> IO(U32 & String):
  do IO<U32 & String>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(prog, args, "", 1048576, 120000)
    return got(r)

def out.of(r: U32 & String) -> String:
  (code, out) = r
  String.trim(out)

def must.if(ok: Bool, what: String, +out: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "wa-send: " ++ what ++ " failed: " ++ out)

def must(what: String, r: U32 & String) -> IO(Unit):
  (+code, +out) = r
  must.if(U32.is_eq(code, 0), what, out)

def check.if(ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 3, "wa-send: the focus moved, or that window is not WhatsApp: nothing more was pressed")

# the active window is w, and it shows WhatsApp's tab
def check(+w: String) -> IO(Unit):
  do IO<Unit>:
    a : U32 & String <- cmd("xdotool", ["getactivewindow"])
    n : U32 & String <- cmd("xdotool", ["getwindowname", w])
    check.if(Bool.and(String.eq(out.of(a), w), String.ends_with(out.of(n), "WhatsApp - Brave")))

def key(k: String) -> IO(Unit):
  do IO<Unit>:
    r : U32 & String <- cmd("xdotool", ["key", "--clearmodifiers", k])
    must("xdotool key", r)

def type.text(t: String) -> IO(Unit):
  do IO<Unit>:
    r : U32 & String <- cmd("xdotool", ["type", "--clearmodifiers", "--delay", "12", t])
    must("xdotool type", r)

def act.run(+w: String, a: Act) -> IO(Unit):
  match a:
    case ACheck{}:
      check(w)
    case AKey{k}:
      key(k)
    case AType{t}:
      type.text(t)
    case AWait{ms}:
      IO.sleep(ms)

def acts.run(+w: String, acts: List<&2, Act>) -> IO(Unit):
  match acts:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case a <> r:
      do IO<Unit>:
        act.run(w, a)
        acts.run(w, r)

def act.show(a: Act) -> String:
  match a:
    case ACheck{}:
      "check the active window"
    case AKey{k}:
      "key " ++ k
    case AType{t}:
      "type " ++ t
    case AWait{ms}:
      "wait " ++ U32.show(ms) ++ " ms"

def acts.show(acts: List<&2, Act>) -> IO(Unit):
  match acts:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case a <> r:
      do IO<Unit>:
        IO.print(act.show(a))
        acts.show(r)

def env.pick(r: Result<&1, &1, U32 & String, String>, d: String) -> String:
  match r:
    case Done{v}:
      v
    case Fail{_}:
      d

def env.or(name: String, +d: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return env.pick(r, d)

# screenshots stay in the runtime directory: tmpfs, this user's only
def shot(name: String) -> IO(String):
  do IO<String>:
    +rt : String <- env.or("XDG_RUNTIME_DIR", "/tmp")
    +dir : String = rt ++ "/wa-send"
    m : U32 & String <- cmd("mkdir", ["-p", "-m", "700", dir])
    must("mkdir", m)
    +path : String = dir ++ "/" ++ name
    r : U32 & String <- cmd("scrot", ["-u", "-o", path])
    must("scrot", r)
    return path

def first.of(ls: List<&2, String>) -> String:
  match ls:
    case Nil{}:
      ""
    case l <> _:
      l

def first.line(s: String) -> String:
  first.of(String.lines(s))

def win.find() -> IO(String):
  do IO<String>:
    r : U32 & String <- cmd("xdotool", ["search", "--onlyvisible", "--name", "WhatsApp - Brave$"])
    return first.line(out.of(r))

def win.wait.if(none: Bool, +w: String, again: IO(String)) -> IO(String):
  match none:
    case False{}:
      IO.pure(String, w)
    case True{}:
      do IO<String>:
        IO.sleep(3000)
        again

# (3 s a try)
def win.wait(t: Nat) -> IO(String):
  match t:
    case 0n:
      IO.die(String, 4, "wa-send: no WhatsApp window came up")
    case 1n+p:
      do IO<String>:
        +w : String <- win.find()
        win.wait.if(String.is_empty(w), w, win.wait(p))

# Brave with the page: a new window, no key pressed
def open.new(url: String) -> IO(String):
  do IO<String>:
    d : String <- env.or("DISPLAY", ":0")
    x : String <- env.or("XAUTHORITY", "")
    r : U32 & String <- cmd("systemd-run", ["--user", "--collect", "--quiet", "--setenv=DISPLAY=" ++ d, "--setenv=XAUTHORITY=" ++ x, "brave", "--new-window", url])
    must("systemd-run brave", r)
    +w : String <- win.wait(40n)
    IO.sleep(45000)
    a : U32 & String <- cmd("xdotool", ["windowactivate", w])
    must("xdotool windowactivate", a)
    IO.sleep(500)
    check(w)
    return w

# the tab that is there: into its address bar
def open.here(+w: String, url: String) -> IO(String):
  do IO<String>:
    a : U32 & String <- cmd("xdotool", ["windowactivate", w])
    must("xdotool windowactivate", a)
    IO.sleep(500)
    acts.run(w, draft.acts(url))
    IO.sleep(45000)
    check(w)
    return w

def open.if(none: Bool, +w: String, url: String) -> IO(String):
  match none:
    case True{}:
      open.new(url)
    case False{}:
      open.here(w, url)

def draft.go(url: String) -> IO(Unit):
  do IO<Unit>:
    +found : String <- win.find()
    +w : String <- open.if(String.is_empty(found), found, url)
    +p : String <- shot("draft.png")
    IO.print("window " ++ w)
    IO.print("screenshot " ++ p)
    IO.print("nothing sent.  See the chat's name and the text there, then: wa-send send " ++ w)

def draft.dry(url: String) -> IO(Unit):
  do IO<Unit>:
    +u : String = url
    IO.print("url " ++ u)
    acts.show(draft.acts(u))

def send.go(+w: String) -> IO(Unit):
  do IO<Unit>:
    acts.run(w, send.acts())
    IO.sleep(8000)
    +p : String <- shot("sent.png")
    IO.print("Enter pressed in window " ++ w)
    IO.print("screenshot " ++ p)

def words(ws: List<String>) -> String:
  match ws:
    case Nil{}:
      ""
    case w <> Nil{}:
      w
    case w <> r:
      w ++ " " ++ words(r)

def usage() -> String:
  "usage: wa-send draft [--dry-run] PHONE TEXT...\n       wa-send send WINDOW"

def with.url.if(ph: Maybe<&2, String>, empty: Bool, +text: String, k: String -> IO(Unit)) -> IO(Unit):
  match ph empty:
    case Some{p} False{}:
      k(send.url(p, text))
    case None{} _:
      IO.die(Unit, 2, "wa-send: PHONE is 10 digits, or + and 8 to 15 digits")
    case _ True{}:
      IO.die(Unit, 2, usage())

def with.url(ph: Maybe<&2, String>, +text: String, k: String -> IO(Unit)) -> IO(Unit):
  with.url.if(ph, String.is_empty(text), text, k)

def wa.args(xs: List<String>) -> IO(Unit):
  match xs:
    case "draft" <> "--dry-run" <> +ph <> ws:
      with.url(phone.norm(ph), words(ws), draft.dry)
    case "draft" <> +ph <> ws:
      with.url(phone.norm(ph), words(ws), draft.go)
    case "send" <> +w <> Nil{}:
      send.go(w)
    case _:
      IO.die(Unit, 2, usage())

def wa.main(xs: List<String>) -> IO(Unit):
  match xs:
    case _ <> rest:
      wa.args(rest)
    case Nil{}:
      IO.die(Unit, 2, usage())

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    wa.main(argv)
