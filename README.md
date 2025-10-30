```sh
git clone https://github.com/jonnymacs/rpi-with-splash-screen
cd rpi-with-splash-screen
./build.sh
```

```sh
docker compose build manager-os
docker compose run --rm manager-os bash
cargo build --release --target aarch64-unknown-linux-gnu
```