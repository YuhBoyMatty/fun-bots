from addons.gets import get_settings, get_settings_lines, get_to_root


def createSettings() -> None:
    get_to_root()
    config_file = "ext/Shared/Config.lua"
    allSettings = get_settings(first_key="Name")

    with open(config_file, "w") as outFile:
        outFile.write(
            """-- this file is autogenerated out of the Settings/SettingsDefinition.lua-file.
-- for permanent changes use this file and regenerate the Config.lua-file.\n
---@class Config
Config = {
    """
        )
        outFileLines = get_settings_lines(allSettings)
        for line in outFileLines:
            outFile.write(line + "\n")
        print("Write Config.lua Done")


if __name__ == "__main__":
    createSettings()
