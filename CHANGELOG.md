# 2021-09-12

- Added `set -euo pipefail` to the script to improve maintainability, and fixed some resulting issues with unbound variables and the like

# 2021-06-22

- Installed a USB ambient temperature sensor on the server and integrated it into the setpoint calculation for the hard drive fan speed calculation. 
  - Set `USE_AMBIENT_TEMP` in the `.env` file to enable or disable this functionality.
  - Set `AMBIENT_COEFF` in the `.env` file to adjust the desired difference between your ambient temperature and average drive temperature setpoint. Somewhere between 12 and 16 should work, depending on how hard you want your fans to work and the typical ambient temperature of your server environment.
