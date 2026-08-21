# DDLC Original Russian Voice Mod v1.0.4b Silero Backend Fix
# Target: original DDLC 2017 / Ren'Py 6.99-era.
# ASCII-only source for old Ren'Py/Python 2 compatibility.

init 999 python:
    import os, re, base64, subprocess

    _rv_process = None
    _rv_null = None
    _rv_enabled = True
    _rv_last = None
    _rv_original_say = None
    _rv_backend = "none"

    def _rv_u(v):
        if v is None:
            return u""
        try:
            if isinstance(v, unicode):
                return v
            return unicode(v, "utf-8", "replace")
        except:
            try:
                return unicode(v)
            except:
                return u""

    def _rv_log(msg):
        try:
            p = os.path.join(config.gamedir, "voice_mod", "mod.log")
            f = open(p, "ab")
            try:
                f.write((_rv_u(msg) + u"\n").encode("utf-8", "replace"))
            finally:
                f.close()
        except:
            pass

    def _rv_clean(v):
        t = _rv_u(v)
        try:
            if hasattr(renpy, "substitute"):
                t = renpy.substitute(t)
        except:
            pass
        t = re.sub(u"\\{[^{}]*\\}", u"", t)
        t = t.replace(u"\r", u" ").replace(u"\n", u" ")
        t = re.sub(u"\\s+", u" ", t).strip()
        if t == u"Don't Skip Previous Line!":
            return u""
        return t

    def _rv_speaker(obj):
        if obj is None:
            return "narrator"

        try:
            st = renpy.store
            for sid, name in (
                ("sayori", "s"),
                ("natsuki", "n"),
                ("yuri", "y"),
                ("monika", "m"),
                ("mc", "mc")
            ):
                try:
                    if obj is getattr(st, name):
                        return sid
                except:
                    pass
        except:
            pass

        val = _rv_u(obj).lower()
        aliases = (
            ("sayori", (u"sayori", u"\u0441\u0430\u0439\u043e\u0440\u0438")),
            ("natsuki", (u"natsuki", u"\u043d\u0430\u0446\u0443\u043a\u0438")),
            ("yuri", (u"yuri", u"\u044e\u0440\u0438")),
            ("monika", (u"monika", u"\u043c\u043e\u043d\u0438\u043a\u0430")),
            ("mc", (u"mc", u"protagonist", u"\u0433\u043b\u0430\u0432\u043d\u044b\u0439 \u0433\u0435\u0440\u043e\u0439"))
        )
        for sid, names in aliases:
            for n in names:
                try:
                    if n in val:
                        return sid
                except:
                    pass
        return "other"

    def _rv_voice_root():
        return os.path.join(config.gamedir, "voice_mod")

    def _rv_neural_root():
        return os.path.join(_rv_voice_root(), "neural")

    def _rv_neural_python():
        return os.path.join(_rv_neural_root(), "venv", "Scripts", "python.exe")

    def _rv_neural_server():
        return os.path.join(_rv_neural_root(), "neural_tts.py")

    def _rv_neural_model():
        return os.path.join(_rv_neural_root(), "models", "v5_5_ru.pt")

    def _rv_neural_ready():
        return os.path.join(_rv_neural_root(), "runtime-ready.flag")

    def _rv_neural_failed():
        return os.path.join(_rv_neural_root(), "failed.flag")

    def _rv_sapi_helper():
        return os.path.join(_rv_voice_root(), "tts_helper.ps1")

    def _rv_ps():
        root = os.environ.get("SystemRoot", r"C:\Windows")
        p = os.path.join(
            root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"
        )
        if os.path.isfile(p):
            return p
        return "powershell.exe"

    def _rv_neural_available():
        return (
            os.path.isfile(_rv_neural_python())
            and os.path.isfile(_rv_neural_server())
            and os.path.isfile(_rv_neural_model())
            and os.path.isfile(_rv_neural_ready())
            and not os.path.isfile(_rv_neural_failed())
        )

    def _rv_log_neural_status():
        try:
            _rv_log(
                "Silero status python=" + str(os.path.isfile(_rv_neural_python())) +
                " server=" + str(os.path.isfile(_rv_neural_server())) +
                " model=" + str(os.path.isfile(_rv_neural_model())) +
                " runtime_ready=" + str(os.path.isfile(_rv_neural_ready())) +
                " failed=" + str(os.path.isfile(_rv_neural_failed()))
            )
        except:
            pass

    def _rv_start():
        global _rv_process, _rv_null, _rv_backend

        try:
            if _rv_process is not None and _rv_process.poll() is None:
                return True
        except:
            pass

        try:
            if _rv_null is None:
                _rv_null = open(os.devnull, "wb")

            si = None
            flags = 0
            if os.name == "nt":
                try:
                    si = subprocess.STARTUPINFO()
                    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                    si.wShowWindow = 0
                except:
                    si = None
                flags = 0x08000000

            if _rv_neural_available():
                args = [
                    _rv_neural_python(),
                    "-u",
                    _rv_neural_server(),
                    "--stdio"
                ]
                _rv_backend = "silero-v5_5"
            else:
                _rv_log_neural_status()
                _rv_log(
                    "ERROR Silero backend is unavailable. "
                    "Automatic Windows SAPI fallback is DISABLED."
                )
                _rv_backend = "none"
                return False

            _rv_process = subprocess.Popen(
                args,
                stdin=subprocess.PIPE,
                stdout=_rv_null,
                stderr=_rv_null,
                cwd=config.basedir,
                startupinfo=si,
                creationflags=flags,
                bufsize=0
            )
            _rv_log("Voice backend process started: " + _rv_backend)
            return True

        except Exception as e:
            _rv_log("ERROR starting voice backend: " + repr(e))
            _rv_process = None
            _rv_backend = "none"
            return False

    def _rv_send(line):
        global _rv_process

        if not _rv_start():
            return False

        try:
            _rv_process.stdin.write(line + "\n")
            _rv_process.stdin.flush()
            return True
        except Exception as e:
            _rv_log("ERROR sending voice command: " + repr(e))
            _rv_process = None
            return False

    def _rv_speak(speaker, text):
        global _rv_last
        t = _rv_clean(text)
        if not t:
            return

        _rv_last = (speaker, t)

        if not _rv_enabled:
            return

        try:
            payload = base64.b64encode(t.encode("utf-8"))
            if not isinstance(payload, str):
                payload = payload.decode("ascii")
            _rv_log("SPEAK speaker=" + speaker + " chars=" + str(len(t)))
            _rv_send("SPEAK|" + speaker + "|" + payload)
        except Exception as e:
            _rv_log("ERROR preparing speech: " + repr(e))

    def _rv_say(who, what, *args, **kwargs):
        try:
            speaker = _rv_speaker(who)
            text = _rv_clean(what)
            if text:
                _rv_log(
                    "SAY captured speaker=" + speaker +
                    " chars=" + str(len(text))
                )
                _rv_speak(speaker, text)
        except Exception as e:
            _rv_log("ERROR in say hook: " + repr(e))

        return _rv_original_say(who, what, *args, **kwargs)

    def _rv_install():
        global _rv_original_say
        try:
            _rv_original_say = renpy.exports.say
            _rv_say._ddlc_russian_voice_hook = True
            renpy.exports.say = _rv_say
            try:
                renpy.say = _rv_say
            except:
                pass
            _rv_log("Say hook installed")
        except Exception as e:
            _rv_log("ERROR installing say hook: " + repr(e))

    def ddlc_tts_toggle():
        global _rv_enabled
        _rv_enabled = not _rv_enabled

        try:
            renpy.notify(
                "Russian neural voice: ON"
                if _rv_enabled
                else "Russian neural voice: OFF"
            )
        except:
            pass

        if not _rv_enabled:
            _rv_send("STOP")

    def ddlc_tts_repeat():
        if _rv_last is not None:
            _rv_speak(_rv_last[0], _rv_last[1])

    def ddlc_tts_test():
        try:
            renpy.notify("Russian neural voice: TEST")
        except:
            pass

        _rv_speak(
            "monika",
            u"\u041f\u0440\u043e\u0432\u0435\u0440\u043a\u0430 \u043d\u0435\u0439\u0440\u043e\u0441\u0435\u0442\u0435\u0432\u043e\u0439 \u0440\u0443\u0441\u0441\u043a\u043e\u0439 \u043e\u0437\u0432\u0443\u0447\u043a\u0438. \u0415\u0441\u043b\u0438 \u0442\u044b \u0441\u043b\u044b\u0448\u0438\u0448\u044c \u044d\u0442\u0443 \u0444\u0440\u0430\u0437\u0443, \u043d\u043e\u0432\u044b\u0439 \u0434\u0432\u0438\u0436\u043e\u043a \u0440\u0430\u0431\u043e\u0442\u0430\u0435\u0442."
        )

    _rv_log("=== DDLC Russian Voice v1.0.4b Silero Backend Fix init ===")
    _rv_install()

    try:
        if "ddlc_russian_voice_hotkeys" not in config.overlay_screens:
            config.overlay_screens.append("ddlc_russian_voice_hotkeys")
    except Exception as e:
        _rv_log("ERROR hotkeys: " + repr(e))

    # Pre-start the backend while the player is still in menus.
    try:
        _rv_start()
    except:
        pass


screen ddlc_russian_voice_hotkeys():
    key "K_F8" action Function(ddlc_tts_toggle)
    key "K_F9" action Function(ddlc_tts_repeat)
    key "K_F10" action Function(ddlc_tts_test)
