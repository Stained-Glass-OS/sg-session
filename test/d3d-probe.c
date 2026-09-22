/* Does Direct3D actually reach Vulkan in this prefix?
 *
 * Checking that DXVK's and VKD3D-Proton's DLLs are installed proves very
 * little: Wine will happily fall back to its own builtins, or the DLLs will
 * load and then fail at device creation because nothing implements Vulkan
 * underneath. Both look like a working installation from the outside.
 *
 * So create a real device on each API and say which implementation answered.
 * Built for both architectures, because a 64-bit-only D3D stack is exactly the
 * kind of gap this project exists to avoid.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
/* INITGUID defines the interface GUIDs in this object rather than importing
 * them: mingw-w64's import libraries do not carry IID_ID3D12Device. */
#define INITGUID
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <initguid.h>
#include <stdio.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi.h>

static void describe_adapter(void)
{
    IDXGIFactory *factory = NULL;
    IDXGIAdapter *adapter = NULL;
    DXGI_ADAPTER_DESC desc;

    if (FAILED(CreateDXGIFactory(&IID_IDXGIFactory, (void **)&factory))) return;
    if (SUCCEEDED(IDXGIFactory_EnumAdapters(factory, 0, &adapter)))
    {
        if (SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &desc)))
            printf("adapter: %ls\n", desc.Description);
        IDXGIAdapter_Release(adapter);
    }
    IDXGIFactory_Release(factory);
}

int main(void)
{
    ID3D11Device *dev11 = NULL;
    ID3D12Device *dev12 = NULL;
    D3D_FEATURE_LEVEL level = 0;
    int rc = 0;
    HRESULT hr;

    printf("arch: %u-bit\n", (unsigned)(sizeof(void *) * 8));
    describe_adapter();

    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                           D3D11_SDK_VERSION, &dev11, &level, NULL);
    if (SUCCEEDED(hr))
    {
        printf("D3D11: OK (feature level 0x%04x)\n", (unsigned)level);
        ID3D11Device_Release(dev11);
    }
    else
    {
        printf("D3D11: FAIL (hr=0x%08lx)\n", (unsigned long)hr);
        rc = 1;
    }

    hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev12);
    if (SUCCEEDED(hr))
    {
        printf("D3D12: OK\n");
        ID3D12Device_Release(dev12);
    }
    else
    {
        printf("D3D12: FAIL (hr=0x%08lx)\n", (unsigned long)hr);
        rc = 1;
    }
    return rc;
}
