import configparser
import sys


class CTFdConfig(configparser.ConfigParser):
    def optionxform(self, optionstr: str) -> str:
        return optionstr


config = CTFdConfig()
with open("/opt/CTFd/CTFd/config.ini") as source:
    config.read_file(source)
config["extra"]["SESSION_COOKIE_SECURE"] = ""  # CTFd types extra values from the environment.
config["security"]["SESSION_COOKIE_HTTPONLY"] = "true"
config["security"]["SESSION_COOKIE_SAMESITE"] = "Lax"
config.write(sys.stdout)
