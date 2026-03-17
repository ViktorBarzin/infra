import asyncio
import logging
import os
import signal
import sys
import time

import aiohttp

iDRAC_HOST = 'idrac'
iDRAC_USER_ENV_VAR = 'idrac_user'
iDRAC_PASSWORD_ENV_VAR = 'idrac_password'
SHOULD_RUN = True


def signal_handler(sig, frame):
    logging.warning(f'signal {sig} received. shutting down gracefully...')
    global SHOULD_RUN
    SHOULD_RUN = False
    time.sleep(60)
    sys.exit(0)


async def main() -> None:
    # define signal handlers
    signal.signal(signal.SIGINT, signal_handler)

    user = os.environ.get(iDRAC_USER_ENV_VAR)
    if user is None:
        logging.critical('missing environment variable for idrac user'
                         f' please set  {iDRAC_USER_ENV_VAR}')
        return

    password = os.environ.get(iDRAC_PASSWORD_ENV_VAR)
    if password is None:
        logging.critical('missing environment variable for idrac password'
                         f' please set  {iDRAC_PASSWORD_ENV_VAR}')
        return

    logging.info('service initiated with credentials')
    return await monitor(user, password)


async def monitor(user: str, password: str) -> None:
    while SHOULD_RUN:
        pass


if __name__ == '__main__':
    # abandoned bc server cannot start itself when it's off :/
    asyncio.run(main())
