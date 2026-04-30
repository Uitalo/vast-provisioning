import os

# upscale_models


local_dir = os.path.abspath(os.path.dirname(__file__))
script_path = os.path.join(local_dir, 'vast-provisioning')
repository = 'https://github.com/Uitalo/vast-provisioning.git'


if not os.path.exists(script_path):
    if os.system('git clone ' + repository):
        print('Repositório clonado com sucesso')
    else:
        raise Exception
else:
    print('Repositorio local já existe')

os.system(f'cd {script_path} &&  git push')



print('Descreva o commit')
_commit = input('Commit > ')

if os.system(f'cd {script_path} && git add . && git commit -m "{_commit}" && git branch -M main && git push') == 0:
    print('Script update com sucesso')
else:
    print('Script update com erro')