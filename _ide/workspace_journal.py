# 2026-07-10T15:34:20.171100600
import vitis

client = vitis.create_client()
client.set_workspace(path="mnist_cnn")

vitis.dispose()

