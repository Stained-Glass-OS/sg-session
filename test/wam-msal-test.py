"""sg-wam-msal and sg-wam-redirect (the sign-in program behind wine-sg's Web Account Manager), no network:
Office's account hint, the id token / client info / scopes every answer carries, the request and answer
protocol, and the redirect hand-back over the socket.  python3 test/wam-msal-test.py  (77: python3-msal missing)"""
import base64
import importlib.machinery
import importlib.util
import io
import json
import os
import socket
import sys
import tempfile
import threading
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "bin")


def load(name):
    path = os.path.join(SRC, name)
    loader = importlib.machinery.SourceFileLoader(name.replace("-", "_"), path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


try:
    import msal  # noqa: F401
except ImportError:
    print("SKIP: python3-msal is not installed")
    sys.exit(77)

wam = load("sg-wam-msal")
OID, TID = "259ddaad-e559-465e-83ce-2411d2a4bfb9", "5f407884-cc81-44c0-a9ff-ccdd10e1452c"
HOME = OID + "." + TID
CLIENT = "d3590ed6-52b3-4102-aeff-aad2292ab01c"


def office_hint(oid=OID, tid=TID):
    """the "O.<base64 protobuf>" Office puts in the login hint: field 1 the object id, field 2 the tenant id"""
    raw = b"\x0a" + bytes([len(oid)]) + oid.encode() + b"\x12" + bytes([len(tid)]) + tid.encode()
    return "O." + base64.urlsafe_b64encode(raw).decode().rstrip("=")


ACCOUNT = {"home_account_id": HOME, "username": "mfinagler@efmpc.com", "environment": "login.microsoftonline.com",
           "realm": TID, "local_account_id": OID}


class FakeCache:
    def __init__(self, entries):
        self.entries = entries

    def find(self, kind, query=None):
        return [e for e in self.entries.get(kind, []) if all(e.get(k) == v for k, v in (query or {}).items())]


class FakeApp:
    def __init__(self, accounts=(ACCOUNT,), entries=None):
        self.accounts = list(accounts)
        self.token_cache = FakeCache(entries or {})

    def get_accounts(self):
        return list(self.accounts)


class AccountHint(unittest.TestCase):
    def test_office_hint_decodes_to_object_and_tenant_id(self):
        self.assertEqual(wam.account_ids_from_hint(office_hint()), (OID, TID))

    def test_an_email_or_junk_is_not_an_office_hint(self):
        for hint in ("mfinagler@efmpc.com", "", "O.", "O.!!!", "O." + base64.b64encode(b"\xff\xff").decode()):
            self.assertEqual(wam.account_ids_from_hint(hint), (None, None), hint)

    def test_account_found_by_office_hint(self):
        other = dict(ACCOUNT, home_account_id="x." + TID, local_account_id="x", username="other@efmpc.com")
        app = FakeApp([other, ACCOUNT])
        self.assertIs(wam.find_account(app, {"login_hint": office_hint()}), ACCOUNT)

    def test_account_found_by_email_or_id(self):
        app = FakeApp()
        self.assertIs(wam.find_account(app, {"login_hint": "MFinagler@efmpc.com"}), ACCOUNT)
        self.assertIs(wam.find_account(app, {"account_id": HOME}), ACCOUNT)

    def test_the_only_account_answers_a_request_naming_none(self):
        self.assertIs(wam.find_account(FakeApp(), {}), ACCOUNT)
        self.assertIsNone(wam.find_account(FakeApp([ACCOUNT, dict(ACCOUNT, home_account_id="b.c")]), {}))

    def test_a_hint_for_another_tenant_does_not_match(self):
        self.assertIsNone(wam.find_account(FakeApp(), {"login_hint": office_hint(tid="00000000-0000-0000-0000-000000000000")}))


class AnswerFields(unittest.TestCase):
    """Office's MSAL refuses an answer without an id token, client info and scopes, a cached one too."""

    def entries(self):
        return {wam.msal.TokenCache.CredentialType.ID_TOKEN: [{"home_account_id": HOME, "secret": "id.token.jwt"}],
                wam.msal.TokenCache.CredentialType.ACCESS_TOKEN: [
                    {"home_account_id": HOME, "target": "https://officeapps.live.com/user_impersonation https://officeapps.live.com/.default"},
                    {"home_account_id": HOME, "target": "https://api.office.net/.default"}]}

    def test_a_cached_answer_gets_what_msal_leaves_out(self):
        res = {"access_token": "a", "expires_in": 3000}
        wam.fill_from_cache(FakeApp(entries=self.entries()), res, ACCOUNT, ["https://officeapps.live.com/.default"])
        self.assertEqual(res["id_token"], "id.token.jwt")
        self.assertEqual(res["scope"], "https://officeapps.live.com/user_impersonation https://officeapps.live.com/.default")
        info = res["client_info"]
        self.assertEqual(json.loads(base64.urlsafe_b64decode(info + "=" * (-len(info) % 4))), {"uid": OID, "utid": TID})

    def test_what_msal_gave_is_kept(self):
        res = {"id_token": "fresh", "client_info": "ci", "scope": "s"}
        wam.fill_from_cache(FakeApp(entries=self.entries()), res, ACCOUNT, ["x"])
        self.assertEqual((res["id_token"], res["client_info"], res["scope"]), ("fresh", "ci", "s"))

    def test_scopes_asked_stand_in_when_the_cache_has_no_match(self):
        res = {}
        wam.fill_from_cache(FakeApp(entries={}), res, ACCOUNT, ["https://x/.default"])
        self.assertEqual(res["scope"], "https://x/.default")


class Protocol(unittest.TestCase):
    """one request on standard input, one SGWAM-RESULT: line out"""

    def call(self, request, app):
        with mock.patch.object(wam, "load_cache", return_value=mock.Mock(has_state_changed=False)), \
             mock.patch.object(wam.msal, "PublicClientApplication", return_value=app), \
             mock.patch.object(sys, "stdin", io.StringIO(json.dumps(request))), \
             mock.patch.object(sys, "stdout", io.StringIO()) as out:
            wam.main()
        line = out.getvalue()
        self.assertTrue(line.startswith("SGWAM-RESULT:") and line.endswith("\n") and line.count("\n") == 1)
        return json.loads(line[len("SGWAM-RESULT:"):])

    def req(self, **kw):
        return dict({"mode": "silent", "authority": "https://login.microsoftonline.com/" + TID, "client_id": CLIENT,
                     "scopes": ["https://officeapps.live.com/.default", "offline_access", "openid", "profile"]}, **kw)

    def test_silent_with_no_account_asks_for_interaction(self):
        out = self.call(self.req(login_hint="nobody@efmpc.com"), FakeApp([]))
        self.assertEqual((out["ok"], out["error"], out["interaction_required"]), (False, "no_account", True))

    def test_silent_answer_carries_the_account_and_the_fields_office_reads(self):
        app = FakeApp(entries={wam.msal.TokenCache.CredentialType.ID_TOKEN: [{"home_account_id": HOME, "secret": "jwt"}]})
        app.acquire_token_silent = mock.Mock(return_value={"access_token": "at", "expires_in": 3000, "token_type": "Bearer"})
        out = self.call(self.req(login_hint=office_hint()), app)
        res = out["result"]
        self.assertTrue(out["ok"])
        self.assertEqual((res["access_token"], res["account"]["home_account_id"], res["id_token"]), ("at", HOME, "jwt"))
        self.assertIn("client_info", res)
        # openid, profile and offline_access are MSAL's own: passing them is an error
        self.assertEqual(app.acquire_token_silent.call_args[0][0], ["https://officeapps.live.com/.default"])

    def test_a_token_msal_cannot_give_silently_is_interaction_required(self):
        app = FakeApp()
        app.acquire_token_silent = mock.Mock(return_value=None)
        out = self.call(self.req(login_hint=office_hint()), app)
        self.assertEqual((out["ok"], out["error"], out["interaction_required"]), (False, "no_token", True))

    def test_accounts_lists_the_signed_in_ones(self):
        out = self.call({"mode": "accounts", "authority": "https://login.microsoftonline.com/organizations", "client_id": CLIENT}, FakeApp())
        self.assertEqual([a["home_account_id"] for a in out["result"]["accounts"]], [HOME])

    def test_a_crash_is_an_answer_not_a_traceback(self):
        out = self.call({"mode": "silent"}, FakeApp())
        self.assertFalse(out["ok"])
        self.assertEqual(out["error"], "KeyError")


class RedirectHandBack(unittest.TestCase):
    """the browser's last hop: sg-wam-redirect gives the ms-appx-web: URL to the program waiting on the socket"""

    def test_the_final_url_reaches_the_waiting_program(self):
        redirect = wam.broker_redirect(CLIENT)
        final = redirect + "?code=abc&state=xyz"
        with tempfile.TemporaryDirectory() as run:
            env = {"XDG_RUNTIME_DIR": run}
            app = mock.Mock()
            app.initiate_auth_code_flow.return_value = {"auth_uri": "https://login.example/authorize", "state": "xyz"}
            app.acquire_token_by_auth_code_flow.return_value = {"access_token": "at"}

            def browser(cmd, **kw):  # stands in for xdg-open: the person signs in, the browser ends on the redirect
                def hand_back():
                    sg = os.path.join(run, "sg-wam-redirect-%d.sock" % os.getuid())
                    code = (
                        "import sys; sys.argv=['sg-wam-redirect', %r]; exec(open(%r).read())" % (final, os.path.join(SRC, "sg-wam-redirect")))
                    for _ in range(50):
                        if os.path.exists(sg):
                            break
                        threading.Event().wait(0.05)
                    # not subprocess: Popen is patched for this test
                    status = os.spawnve(os.P_WAIT, sys.executable, [sys.executable, "-c", code], dict(os.environ, **env))
                    assert status == 0
                threading.Thread(target=hand_back, daemon=True).start()
                return mock.Mock()

            with mock.patch.dict(os.environ, env), mock.patch.object(wam.subprocess, "Popen", side_effect=browser):
                res = wam.interactive_sign_in(app, {"client_id": CLIENT, "login_hint": "mfinagler@efmpc.com"}, ["s"])
            self.assertEqual(res, {"access_token": "at"})
            self.assertEqual(app.initiate_auth_code_flow.call_args[1]["redirect_uri"], redirect)
            self.assertEqual(app.initiate_auth_code_flow.call_args[1]["login_hint"], "mfinagler@efmpc.com")
            self.assertEqual(app.acquire_token_by_auth_code_flow.call_args[0][1], {"code": "abc", "state": "xyz"})
            self.assertFalse(os.path.exists(os.path.join(run, "sg-wam-redirect-%d.sock" % os.getuid())))

    def test_the_redirect_with_no_one_waiting_is_ignored(self):
        with tempfile.TemporaryDirectory() as run:
            code = "import sys; sys.argv=['x','ms-appx-web://a/b']; exec(open(%r).read())" % os.path.join(SRC, "sg-wam-redirect")
            status = os.spawnve(os.P_WAIT, sys.executable, [sys.executable, "-c", code], dict(os.environ, XDG_RUNTIME_DIR=run))
            self.assertEqual(status, 0)


if __name__ == "__main__":
    unittest.main()
