"""
Open an AutoRewarder account browser without running automation.

Usage:
    python account.py
"""

import time

from src.config import edge_profile_path
from src.accounts import AccountManager, GlobalSettingsManager
from src.emulator.driver import DriverManager


def load_accounts():
    """Return the project account manager after running legacy migration."""
    global_settings = GlobalSettingsManager()
    account_manager = AccountManager(global_settings)
    account_manager.migrate_legacy()
    return account_manager


def _setup_status(account):
    """Return a short setup status label for display."""
    return "ready" if account.get("first_setup_done") else "setup pending"


def print_accounts(accounts, print_func=print):
    """Print the selectable account list."""
    print_func("AutoRewarder accounts:")
    for index, account in enumerate(accounts, start=1):
        current = " * current" if account.get("is_current") else ""
        print_func(
            f"  {index}. {account['label']} "
            f"({account['id']}, {_setup_status(account)}{current})"
        )


def choose_account(accounts, input_func=input, print_func=print):
    """
    Prompt until the user chooses an account by list number or account id.

    Returns:
        dict | None: selected account, or None when the user quits.
    """
    print_accounts(accounts, print_func=print_func)
    print_func("")

    while True:
        choice = input_func("Choose an account number/id, or q to quit: ").strip()
        if choice.lower() in {"q", "quit", "exit"}:
            return None

        if choice.isdigit():
            index = int(choice)
            if 1 <= index <= len(accounts):
                return accounts[index - 1]

        for account in accounts:
            if choice == account["id"]:
                return account

        print_func("Invalid choice. Try again.")


def open_browser_for_account(account):
    """
    Open Edge with the selected account profile and wait until it closes.

    Args:
        account: account entry from AccountManager.list()
    """
    driver = DriverManager(
        profile_path=edge_profile_path(account["id"]),
        hide_browser=False,
    ).setup_driver(headless=False, disable_identity=False)

    try:
        driver.get("https://www.bing.com/")
        print("Browser opened. Close the Edge window when you are done.")
        while len(driver.window_handles) > 0:
            time.sleep(1)
    except Exception as exc:
        message = str(exc).lower()
        if (
            "target window already closed" not in message
            and "disconnected" not in message
            and "not reachable" not in message
        ):
            raise
    finally:
        try:
            driver.quit()
        except Exception:
            pass


def main():
    """CLI entry point."""
    account_manager = load_accounts()
    accounts = account_manager.list()
    if not accounts:
        print("No AutoRewarder accounts found. Create an account in the app first.")
        return 1

    account = choose_account(accounts)
    if account is None:
        return 0

    print(f"Opening browser for {account['label']}...")
    open_browser_for_account(account)
    print("Browser closed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
