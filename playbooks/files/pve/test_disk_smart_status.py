"""Tests for disk-smart-status, against smartctl JSON shaped like the R730's drives.

    python3 -m pytest playbooks/files/pve/test_disk_smart_status.py

The fixtures carry the fields and values smartctl 7.5 returned on 2026-11-09
for an Exos X24 (SAS, with FARM), an ST600MM0069 (SAS, no FARM) and the
Samsung 850 EVO (SATA), each read through the PERC with -d megaraid,N.
"""

import importlib.machinery
import importlib.util
import re
from pathlib import Path

import pytest

HERE = Path(__file__).parent
_loader = importlib.machinery.SourceFileLoader("dss", str(HERE / "disk-smart-status"))
_spec = importlib.util.spec_from_loader("dss", _loader)
dss = importlib.util.module_from_spec(_spec)
_loader.exec_module(dss)


def exos() -> dict:
    return {
        "_type": "megaraid,0",
        "smartctl": {"exit_status": 0},
        "model_name": "SEAGATE ST12000NM007H",
        "scsi_model_name": "SEAGATE ST12000NM007H",
        "serial_number": "ZZ301LW9",
        "logical_block_size": 512,
        "smart_status": {"passed": True},
        "temperature": {"current": 32, "drive_trip": 50},
        "power_on_time": {"hours": 9597, "minutes": 3},
        "scsi_grown_defect_list": 0,
        "scsi_pending_defects": {"count": 0},
        "scsi_error_counter_log": {
            "read": {"total_errors_corrected": 0, "gigabytes_processed": "199224.371", "total_uncorrected_errors": 0},
            "write": {"total_errors_corrected": 217, "gigabytes_processed": "472546.502", "total_uncorrected_errors": 0},
            "verify": {"total_errors_corrected": 0, "gigabytes_processed": "0.000", "total_uncorrected_errors": 0},
        },
        "scsi_start_stop_cycle_counter": {
            "accumulated_load_unload_cycles": 427,
            "specified_load_unload_count_over_device_lifetime": 600000,
        },
        "seagate_farm_log": {
            "supported": True,
            "workload_statistics": {
                "logical_sectors_written": 344478286497,
                "logical_sectors_read": 161011431118,
            },
        },
    }


def sas600() -> dict:
    return {
        "_type": "megaraid,6",
        "smartctl": {"exit_status": 0},
        "scsi_model_name": "SEAGATE ST600MM0069",
        "serial_number": "WFJ01QPE",
        "logical_block_size": 512,
        "smart_status": {"passed": True},
        "temperature": {"current": 27, "drive_trip": 60},
        "power_on_time": {"hours": 65548},
        "scsi_grown_defect_list": 0,
        "scsi_error_counter_log": {
            "read": {"total_errors_corrected": 1790581289, "gigabytes_processed": "75232.519", "total_uncorrected_errors": 0},
        },
        "seagate_farm_log": {"supported": False},
    }


def ssd() -> dict:
    def attr(id_: int, name: str, value: int, raw: int) -> dict:
        return {"id": id_, "name": name, "value": value, "raw": {"value": raw, "string": str(raw)}}

    return {
        "_type": "megaraid,4",
        "smartctl": {"exit_status": 0},
        "model_name": "Samsung SSD 850 EVO 1TB",
        "serial_number": "S2RFNX0J411986X",
        "logical_block_size": 512,
        "smart_status": {"passed": True},
        "temperature": {"current": 22},
        "power_on_time": {"hours": 20952},
        "ata_smart_attributes": {"table": [
            attr(5, "Reallocated_Sector_Ct", 100, 0),
            attr(177, "Wear_Leveling_Count", 97, 62),
            attr(241, "Total_LBAs_Written", 99, 84331706931),
        ]},
    }


def samples(drive: dict) -> dict[str, float]:
    return {f"{m}{l}": v for m, l, v in dss.drive_samples(drive)}


def value(drive: dict, metric: str, **want: str) -> float:
    for m, lbl, v in dss.drive_samples(drive):
        if m == metric and all(f'{k}="{w}"' in lbl for k, w in want.items()):
            return v
    raise KeyError(f"{metric} {want}")


def test_exos_core_health():
    d = exos()
    assert value(d, "smart_read_ok") == 1
    assert value(d, "smart_healthy") == 1
    assert value(d, "smart_temperature_celsius") == 32
    assert value(d, "smart_temperature_trip_celsius") == 50
    assert value(d, "smart_power_on_hours") == 9597
    assert value(d, "smart_grown_defects") == 0
    assert value(d, "smart_pending_defects") == 0
    assert value(d, "smart_load_unload_cycles_total") == 427
    assert value(d, "smart_load_unload_cycles_rated") == 600000


@pytest.mark.parametrize("op,uncorrected,corrected", [("read", 0, 0), ("write", 0, 217), ("verify", 0, 0)])
def test_exos_error_counters_per_op(op, uncorrected, corrected):
    d = exos()
    assert value(d, "smart_uncorrected_errors_total", op=op) == uncorrected
    assert value(d, "smart_corrected_errors_total", op=op) == corrected


def test_farm_gives_logical_bytes_and_processed_bytes_stay_separate():
    d = exos()
    assert value(d, "smart_logical_written_bytes_total", source="farm") == 344478286497 * 512
    assert value(d, "smart_logical_read_bytes_total", source="farm") == 161011431118 * 512
    assert value(d, "smart_processed_bytes_total", op="write") == 472546502000000


def test_labels_carry_bay_model_serial():
    lbl = next(l for m, l, _ in dss.drive_samples(exos()) if m == "smart_healthy")
    assert lbl == '{bay="0",model="SEAGATE ST12000NM007H",serial="ZZ301LW9"}'


def test_sas_without_farm_has_no_logical_bytes():
    names = {m for m, _, _ in dss.drive_samples(sas600())}
    assert "smart_logical_written_bytes_total" not in names
    assert "smart_pending_defects" not in names
    assert value(sas600(), "smart_temperature_trip_celsius") == 60


def test_ssd_attributes_and_written_bytes():
    d = ssd()
    assert value(d, "smart_ata_attribute_normalized", attribute="Wear_Leveling_Count") == 97
    assert value(d, "smart_ata_attribute_raw", attribute="Reallocated_Sector_Ct") == 0
    assert value(d, "smart_logical_written_bytes_total", source="ata") == 84331706931 * 512
    names = {m for m, _, _ in dss.drive_samples(d)}
    assert "smart_temperature_trip_celsius" not in names
    assert "smart_grown_defects" not in names


@pytest.mark.parametrize("exit_status,readable", [(0, 1), (4, 1), (8, 1), (64, 1), (1, 0), (2, 0), (6, 0)])
def test_exit_status_bits_0_and_1_mean_unreadable(exit_status, readable):
    d = exos()
    d["smartctl"]["exit_status"] = exit_status
    assert value(d, "smart_read_ok") == readable
    assert value(d, "smart_smartctl_exit_status") == exit_status
    names = {m for m, _, _ in dss.drive_samples(d)}
    assert ("smart_healthy" in names) == bool(readable)


def test_failed_health_is_zero():
    d = exos()
    d["smart_status"] = {"passed": False}
    assert value(d, "smart_healthy") == 0


def test_empty_json_from_a_dead_drive():
    d = {"_type": "megaraid,3", "smartctl": {"exit_status": 2}}
    assert samples(d) == {
        'smart_smartctl_exit_status{bay="3",model="",serial=""}': 2,
        'smart_read_ok{bay="3",model="",serial=""}': 0,
    }


def test_render_is_valid_exposition():
    text = dss.render([exos(), sas600(), ssd()], now=1794185596.7)
    line = re.compile(r'^[a-z_]+\{[^}]*\} -?[0-9.e+]+$|^[a-z_]+ -?[0-9.e+]+$|^# (HELP|TYPE) [a-z_]+ .+$')
    for ln in text.strip().splitlines():
        assert line.match(ln), ln
    # one HELP/TYPE header per family, never repeated
    types = [ln for ln in text.splitlines() if ln.startswith("# TYPE")]
    assert len(types) == len(set(types))
    assert "smart_collector_drives 3" in text
    assert "smart_collector_last_run_timestamp_seconds 1794185596" in text
    # large counters must not be written in scientific notation
    assert f'source="farm"}} {344478286497 * 512}' in text
