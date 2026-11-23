.PHONY: app run test clean
app:   ; scripts/build-app.sh
run:   ; scripts/build-app.sh --run
test:  ; swift test
clean: ; rm -rf .build build
