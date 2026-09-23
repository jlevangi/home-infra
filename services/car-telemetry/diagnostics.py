import re

# Common generic SAE powertrain codes seen frequently in passenger vehicles.
# Unknown and manufacturer-specific codes retain their code and system classification.
DTC_DESCRIPTIONS = {
    "P0010": "Intake camshaft position actuator circuit, bank 1",
    "P0011": "Intake camshaft timing over-advanced, bank 1",
    "P0012": "Intake camshaft timing over-retarded, bank 1",
    "P0101": "Mass or volume airflow sensor range/performance",
    "P0113": "Intake air temperature sensor circuit high input",
    "P0128": "Coolant thermostat temperature below regulating temperature",
    "P0171": "Fuel system too lean, bank 1",
    "P0172": "Fuel system too rich, bank 1",
    "P0300": "Random or multiple cylinder misfire detected",
    "P0301": "Cylinder 1 misfire detected",
    "P0302": "Cylinder 2 misfire detected",
    "P0303": "Cylinder 3 misfire detected",
    "P0304": "Cylinder 4 misfire detected",
    "P0305": "Cylinder 5 misfire detected",
    "P0325": "Knock sensor 1 circuit malfunction",
    "P0420": "Catalyst system efficiency below threshold, bank 1",
    "P0442": "Evaporative emission system leak detected (small leak)",
    "P0455": "Evaporative emission system leak detected (large leak)",
    "P0507": "Idle control system RPM higher than expected",
    "P0562": "System voltage low",
    "P0700": "Transmission control system malfunction request",
}

SYSTEMS = {
    "P": "Powertrain",
    "C": "Chassis",
    "B": "Body",
    "U": "Network",
}


def decode_dtcs(raw: str | None) -> list[dict]:
    if not raw or raw.strip().lower() in {"none", "unknown"}:
        return []

    codes = []
    for code in re.findall(r"\b[PCBU][0-3][0-9A-F]{3}\b", raw.upper()):
        if any(item["code"] == code for item in codes):
            continue
        generic = code[1] == "0"
        codes.append({
            "code": code,
            "system": SYSTEMS[code[0]],
            "scope": "Generic SAE" if generic else "Manufacturer-specific",
            "description": DTC_DESCRIPTIONS.get(
                code,
                "Description unavailable in the local code catalog"
            ),
        })
    return codes
