# blade 23 — dois PCs

Esta pasta contém o Sentinel modificado, um loader remoto, um servidor de comunicação e um iniciador para Windows. O servidor usa apenas a biblioteca padrão do Python 3.10 ou superior.

## 1. Preparar o PC que será o servidor

1. No PC servidor, baixe apenas `blade23_server.py` e `iniciar_servidor.bat` para a mesma pasta.
2. Com Python instalado, abra `iniciar_servidor.bat`.
3. Deixe a janela aberta. Ela mostra o endereço do servidor e a chave de acesso.
4. Se o Windows solicitar permissão de rede, permita na rede privada usada pelos dois PCs.

O arquivo `blade23_access_key.txt` é criado automaticamente e mantém a chave após reiniciar. O banco `blade23_state.sqlite3` guarda os registros de coordenação.

## 2. Carregar o script nos dois PCs

Pare a versão anterior antes de carregar. Nos dois PCs, use o mesmo comando abaixo no executor. Ele busca a versão atual do GitHub; não exige baixar o `.lua` manualmente.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/main/blade23/loader.lua", true))()
```

Tudo foi reunido na aba principal **blade 23**:

- **Blade / Sigil:** preparação, itens, ponto de coleta/espera, XP, método de Orderly e progressão até Ultra.
- **Cela XP:** ponto exato de ataque, limites da cela, alvos, calibração e ajustes de M1.
- **Rot e filas:** contas fornecedoras, Master, fila das receptoras e contagem de Rots.
- **Comunicacao entre PCs:** modo de comunicação, endereço, chave e teste de conexão.

## 3. Conectar as contas

Com a progressão e o Rot Bot parados, em **blade 23 → Comunicacao entre PCs**:

1. Escolha **Remote HTTP**.
2. No PC que hospeda o servidor, pode usar `http://127.0.0.1:8787`.
3. No outro PC, use o endereço com o IP do primeiro, por exemplo `http://192.168.1.10:8787`. O endereço real aparece na janela do servidor; `127.0.0.1` no segundo PC apontaria para ele mesmo.
4. Cole a **mesma chave de acesso**.
5. Clique **Salvar configuracao de rede** e depois **Testar conexao**. Deve aparecer **Conectado ao Blade 23**.

Faça a configuração em cada instância do Sentinel que já estiver aberta. Instâncias abertas depois leem a configuração salva na pasta local do executor daquele PC.

Todas as contas devem estar no **mesmo servidor do jogo**, mesmo usando PCs diferentes. Não é necessário compartilhar a pasta workspace pela rede no modo Remote HTTP.

## 4. Iniciar a automação

### Contas que vão virar Blade/Sigil

1. Em **Blade / Sigil**, escolha **Blade/Sigil (3 stages)**.
2. Selecione **Rots** ou **Quests**.
3. Marque o ponto de coleta perto da Alana e o ponto de espera. Confira o spawn/inn escolhido.
4. Confira o silver inicial, padrão 660, incluindo 10 da espada. O valor é ajustável.
5. Calibre a cela seguindo a seção abaixo. Confira a meta de dano, padrão 6.700, e a quantidade mínima de Shriekers, padrão 50. Para testar apenas essa cela, escolha **Shriekers** em **Blade XP preference**. **Automatic** também permite o farm alternativo de Zombie Scrooms.
6. Em **Rot e filas → Alts**, selecione somente as contas fornecedoras que serão entregues ao Officer.
7. Habilite Blatant Mode, deixe **Start Phase em Resume** e use **Start**.

O fluxo entra automaticamente na fila de Rots ao terminar o XP. Não é necessário ativar manualmente **Join receiver queue** nesse fluxo completo.

### Contas que fornecem os Rots

1. Em **Rot e filas**, deixe **Alts vazio**.
2. Ative **Enable Rot Bot** e habilite Blatant Mode conforme exigido pelo Sentinel.
3. Não ative a progressão nem **Join receiver queue** nessas contas.
4. Deixe **Retomar fornecedor apos hop/rejoin** ativado se quiser que a fornecedora reinicie automaticamente.

O Master é atualizado automaticamente quando uma receptora inicia o turno e quando termina as 16 entregas confirmadas.

Depois de preparar as condições de Rot, a fornecedora permanece esperando em Renova. Ela só anda até a receptora e se downa quando a receptora da vez está presente, com o Rot Bot ativo, perto de Renova, livre para pegar outra conta e ainda abaixo de 16 Rots. Enquanto a receptora carrega uma conta ou ainda não chegou, as fornecedoras esperam. Um Master preenchido manualmente não substitui essa confirmação da fila.

Use **Parar Rot Bot e cancelar retomada** para parar. A tecla padrão é **F8**, configurável em **Tecla para parar Rot Bot**. Parar cancela a retomada até ativar o Rot Bot novamente.

O rejoin busca novamente o loader do GitHub e executa a versão publicada do Blade 23. O executor precisa oferecer `queue_on_teleport` ou `queueteleport` e ter conexão com o GitHub. Não é preciso manter o script principal na workspace. Se o executor exigir reinjeção manual após trocar de servidor, faça essa etapa no executor.

### Marcar a cela exata de Sanguine Shrine

Faça isso com a progressão parada, usando uma conta dentro da cela desejada:

1. Vá ao ponto onde quer que o personagem dê M1, olhe para os Shriekers e clique **blade 23 → Cela XP → Marcar ponto de M1 + direcao**. A direção salva é a do personagem.
2. Vá a um canto da cela, por dentro das paredes, e clique **Marcar canto A**.
3. Vá ao canto diagonalmente oposto, ainda por dentro da mesma cela, e clique **Marcar canto B**. Os cantos delimitam um retângulo nos eixos do mapa; a área verde permite conferir o resultado.
4. Clique **Ver area e alvos da cela**. Verde mostra os limites e os alvos selecionados, azul mostra o ponto de ataque e amarelo a direção inicial. Confira se foram selecionados os 50 Shriekers desejados, sem incluir a cela vizinha. O HP é lido individualmente; a quantidade visual de contornos pode ser limitada pelo Roblox.
5. Clique **Salvar/compartilhar cela XP**. Com os dois PCs na mesma rede do Blade 23, as outras instâncias recebem a configuração em até cerca de 5 segundos. Sem rede, a marcação fica local; use o JSON para importar nos outros executores.
6. Clique **Copiar calibracao da cela** e cole o texto na conversa para revisar o lugar e a distribuição dos mobs. Também é gravado `blade23_calibracao_xp.json` na workspace do executor, quando `writefile` está disponível.

Para importar: cole o relatório em **JSON da cela**, clique **Importar calibracao**, confira a área e salve/compartilhe.

O farm verifica HP cheio apenas ao iniciar a sessão de XP. Durante o combate, soma as quedas de HP de cada Shrieker observado na área; curas só atualizam a referência do HP e não somam nem subtraem do total. A sessão mantém a mesma cela até terminar, mesmo se outra instância editar a configuração.

O M1 procura a direção com mais alvos dentro do alcance e arco estimados. Pode andar até **1,5 stud** do ponto marcado por padrão; o limite é ajustável de 0 a 3 studs. Paredes e piso são verificados antes dos passos. Se um passo ficar bloqueado, tenta atacar da posição atual. **0** desativa os passos. A câmera pode acompanhar a mira e é restaurada ao terminar.

Alcance e arco são estimativas geométricas ajustáveis, não a hitbox oficial do jogo. A contagem de dano continua vindo do HP, inclusive quando um único M1 acerta vários mobs. A eficácia da mira precisa ser conferida no jogo com sua distribuição real de Shriekers.

### Treino de Warrior com Alfric

Na rota **Blade/Sigil (3 stages)**, tanto por Rots quanto por Quests, o treino exige apenas **Pommel Strike**, **Action Surge** e **Plate Training**. Não compra uma quarta skill para satisfazer `MercenaryCarry`. Skills já obtidas são puladas; cada nova compra aguarda confirmação antes de pagar de novo. O restante da progressão segue a sequência existente.

## O que é compartilhado

- Reservas e fila dos farms de Shriekers e Zombie Scrooms.
- Fila das contas receptoras de Rot, contagem do turno e Master.
- Identificação das contas participantes do Rot Bot.
- Cela XP publicada, incluindo ponto de ataque, direção e limites. O save de XP individual não é compartilhado.

O save individual da progressão continua local. Mover a mesma conta para outro PC não transfere automaticamente esse save.

Se o servidor de comunicação ficar indisponível, as filas remotas não passam a funcionar isoladamente em cada PC. As rotinas mostram erro ou pausam suas ações de coordenação. Um participante sem atualização perde a reserva após cerca de 12 segundos. Ao voltar após expirar, recebe nova ordem de entrada.

## Se os PCs estiverem em redes diferentes

Use um endereço acessível aos dois por uma VPN privada ou hospede o serviço com HTTPS. O programa aceita certificados TLS com `--cert certificado.pem --key chave.pem`. O endereço local mostrado pelo programa só funciona dentro da rede correspondente.

## Se não conectar

- Confira se a janela do servidor está aberta.
- Confira IP, porta 8787 e a mesma chave nas contas.
- Verifique se o firewall permite a conexão na rede privada.
- O executor precisa disponibilizar `request`, `http_request` ou uma função compatível.
- Copie o erro mostrado no botão de teste ou no status da fila para diagnóstico.

Foram verificados: compilação Luau, contagem de XP com cura e retomada, HP cheio apenas na entrada, filas de XP/Rot, bloqueios da fornecedora, três skills de Alfric, carregamento remoto do Blade 23 no rejoin, limites da cela e planejamento geométrico do M1. Os testes de rede cobrem autenticação HTTP, comunicação entre clientes, ordem de chegada pelo servidor, persistência e recuperação de participantes expirados. A validação física em dois PCs e dentro do jogo ainda depende do teste no seu ambiente.
