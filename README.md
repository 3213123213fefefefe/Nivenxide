# Hydroxide Local + Vanguard Tracker

Copia local do Hydroxide (zyu/hydroxide) com painel passivo de timers Vanguard.
Licenca original preservada em HYDROXIDE_LOCAL/LICENSE; consulte-a para redistribuicao.

## Instalar
Extraia HYDROXIDE_LOCAL na pasta workspace do executor. Execute:

```lua
loadstring(readfile("HYDROXIDE_LOCAL/start.lua"))()
```

Abra a aba **Cooldowns**. Em Configurar skill, selecione a habilidade e ajuste
Cooldown (segundos). Blade Crash tambem tem Duracao do efeito (segundos).
Cada skill tem seu proprio nome no painel e opcao Rastrear.
Em Painel e aparencia, configure cores, 0/1/2 casas decimais, visibilidade das
skills sem CD ativo, efeito e reinicio a cada ativacao. O reinicio esta desligado
por padrao para cliques repetidos nao prolongarem o cooldown.
Clique Mostrar painel de timers para ativar Status Effects; arraste o painel
para posicionar. As configuracoes ficam nos perfis de Config: crie/salve um perfil
e carregue-o ou configure autoload para recuperar seus ajustes.
Skills: Brandish, Puncture, Azure Ignition e Blade Crash. Confirme em jogo se
essas sao as skills da sua classe; os nomes vieram da lista do codigo original.

## Medir sem inventar tempos
Os campos com 0 indicam tempo desconhecido. Use uma skill e veja se o painel
registra o uso. Se nao registrar, selecione a skill e clique em Registrar uso
imediatamente depois de uma ativacao bem-sucedida.
Quando conseguir usa-la novamente, clique em Skill ficou pronta: medir CD.
Para Blade Crash, clique em Efeito Blade Crash acabou: medir assim que o efeito
visual/bonus terminar. Repita algumas vezes para conferir e ajuste os segundos.
A medicao inclui seu tempo de reacao. Nao use a medicao caso a ativacao falhe.
As configuracoes podem ser salvas pelo sistema de perfis existente do Hydroxide.

## Limites
O tracker ignora Tool.Activated/M1 e observa AnimationPlayed no Animator local.
As IDs sao lidas das animacoes dentro dos Tools identificados no dump do jogo.
A primeira animacao exclusiva observada de cada skill e aprendida e salva em
Config. Animacoes compartilhadas entre skills nao sao atribuidas automaticamente.
O campo ID da animacao permite corrigir manualmente ou reaprender a deteccao.
Playback de animacao NAO comprova aceite pelo servidor: confirme em jogo se o
contador permanece parado nos cliques recusados durante cooldown.
Depois de configurados, os contadores sao ESTIMATIVAS; nao consultam o servidor.
Em Medicao e controle, Medir intervalo entre dois usos arma a skill selecionada:
a primeira animacao inicia a medicao; a segunda salva o intervalo (3 decimais).
Cliques sem a animacao aprendida sao ignorados. O intervalo inclui o atraso da
proxima tentativa e eventos sao medidos no cliente; nao ha precisao garantida
no servidor. Duplicatas em menos de 0.3s sao filtradas. Reset/respawn cancela medicao.
Nao ha deteccao automatica confirmada de fim do efeito. O timer de efeito do Blade Crash inicia no evento Stopped da animacao de voo,
seja ao executar com M1, cancelar com X ou expirar a preparacao. Durante a
animacao, o painel mostra preparando (voo). Um mesmo campo de duracao serve
para o buff do cancelamento e a imunidade de queda da execucao. O painel usa
um nome generico de efeito, sem inferir qual resultado ocorreu.
ID animacao de voo vazio aprende a primeira animacao em loop exclusiva do
Blade Crash. Se ela nao estiver marcada como Looped ou houver outro loop,
preencha o ID correto; isso ainda exige verificacao em jogo. A ID de voo e
separada da ID que dispara o cooldown. Morte, reset, desativacao e troca de
personagem descartam animacoes pendentes.
O tracker nao aciona skills, nao dispara remotes e nao altera cooldowns.
Status Effects deve ficar ligado para mostrar os contadores. Desligar apenas
Status Effects esconde o painel, mas o tracker continua registrando usos.
Desligar Ativar rastreamento limpa e pausa o tracker.
Morte (quando Humanoid ja existe), remocao e troca de personagem limpam timers.

## Validacao
Modulo testado com Lua 5.4 e objetos simulados: tempos desconhecidos, medicao,
medicao duplicada, cliques repetidos, valor negativo, reset e desativacao,
selecao de skill, campos visiveis, configuracao separada, nomes, decimais,
ocultacao de inativos/efeito, reinicio e desativacao individual, aprendizado de
animacao, M1 sem animacao ignorado e medicao automatica entre duas animacoes,
inicio do efeito somente ao parar o voo, evento de parada duplicado,
reset/desativacao durante voo e selecao explicita da ID de voo.
Integracao conferida por inspecao de escopo. Sem teste no Roblox/Potassium.
O restante do Hydroxide foi preservado, sem validacao dos seus demais recursos.

## GitHub
Pacote organizado para envio na raiz de um repositorio novo.
Loader direto (instala automaticamente e usa cache local nas proximas execucoes):
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/main/loader.lua", true))()
```
O loader fixa uma versao do runtime; novas versoes sao aplicadas quando o loader
remoto atualiza a referencia. Reentre no servidor antes de recarregar uma versao.
Nao coloque tokens, senhas ou cookies no repositorio nem no executor.
