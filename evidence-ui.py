import base64, subprocess,sys,os
from playwright.sync_api import sync_playwright
n=sys.argv[1]
with sync_playwright() as pw:
    b=pw.chromium.launch(executable_path='/usr/bin/google-chrome',args=['--no-sandbox'])
    page=b.new_page(ignore_https_errors=True, viewport={'width':1500,'height':950})
    page.goto('https://localhost:8443/applications/argocd/wine-classifier',wait_until='domcontentloaded')
    passwd=base64.b64decode(subprocess.check_output(['kubectl','-n','argocd','get','secret','argocd-initial-admin-secret','-o','jsonpath={.data.password}'])).decode()
    page.locator('input').first.fill('admin')
    page.locator('input[type=password]').fill(passwd)
    page.locator('input[type=password]').press('Enter')
    page.get_by_text('Healthy',exact=False).first.wait_for(timeout=60000)
    page.get_by_text('Synced',exact=False).first.wait_for()
    if n=='21':
        history=page.get_by_text('History and Rollback',exact=False)
        if history.count():history.first.click()
    page.wait_for_timeout(1200)
    page.screenshot(path=f'evidence/{n}.png')
    b.close()
