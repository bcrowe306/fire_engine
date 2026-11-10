"""Fixtures for the e2e tests: a fresh Pads for each test (its own
preferences and project), with a screenshot kept when a test fails."""

import os
import shutil

import pytest

from pads import ROOT, Pads

LIBRARY = os.path.join(ROOT, "tests", "app_ui", "fixtures", "library")
FIXTURES = os.path.join(ROOT, "tests", "app_ui", "fixtures")
SHOTS = os.path.join(ROOT, ".build", "app", "e2e")


@pytest.hookimpl(tryfirst=True, hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    rep = outcome.get_result()
    setattr(item, "rep_" + rep.when, rep)


@pytest.fixture
def app(request):
    out = os.path.join(SHOTS, request.node.name)
    shutil.rmtree(out, ignore_errors=True)
    pads = Pads(out_dir=out)
    yield pads
    failed = getattr(request.node, "rep_call", None) is not None and request.node.rep_call.failed
    if failed and not pads.closed and pads.proc.poll() is None:
        try:
            print("screenshot of the failure:", pads.screenshot("failure"))
        except Exception as e:  # the app may be the reason
            print("no screenshot:", e)
    pads.close()


@pytest.fixture
def library():
    return LIBRARY


@pytest.fixture
def fixtures():
    return FIXTURES
