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

## Reiniciar sem rejoin
Em Config > Utility, Restart Script fica logo abaixo de Unload Script.
O botao busca e compila o loader atual, salva os ajustes em __nivenxide_restart,
descarrega a sessao atual e executa o loader novamente. A nova sessao restaura
os ajustes depois do autoload. Falhas de download/compilacao ou salvamento antes
do unload deixam a sessao atual aberta. Temporizadores em andamento reiniciam;
NoFall continua dependendo do marcador real presente no personagem.
Testado com objetos simulados: ordem de preparacao/unload, restauracao pendente,
protecoes contra cliques duplicados e falhas de rede/compilacao/salvamento.

## Indicadores na hotbar e nos pes
Em Cooldowns > Painel e aparencia > Indicadores no jogo, os novos indicadores
vem ligados. A cobertura cinza sobre cada skill usa opacidade de 40%, ajustavel
entre 1 e 100%. A cobertura fica como filha do slot, com margem interna de 4px,
sem cobrir a borda decorativa. Sua borda superior desce ate desaparecer ao fim do cooldown;
os segundos podem ser ocultados. E necessario configurar/medir o CD da skill.
As coberturas nao capturam cliques, seguem os slots de BackpackGui/MainFrame
e funcionam independentemente da janela Status Effects.
Uma faixa branca fina em zigue-zague aparece abaixo dos pes somente enquanto o personagem tem
NoFall (instance ou tag), incluindo as fontes que compartilham esse marcador.
Sem marcador, nem o timer estimado do Blade ativa o indicador. Ao remover a
protecao, o indicador some imediatamente no proximo frame. Duracoes conhecidas
sao estimadas: TPSafe 4s e NoPotions/Feather Feet 30s conforme o Hydroxide;
Blade usa a duracao configurada quando o inicio corresponde ao marcador.
Quando nao ha prazo conhecido, a faixa continua visivel sem numero. Quando ha
prazo conhecido, mostra somente os segundos abaixo da faixa, sem texto de status.
A faixa segue a base dos pes/pernas reais em R6 e R15; altura padrao -0.2 stud,
ajustavel entre -1.5 e 1. Ela fica visivel mesmo proxima do chao. Protecao ja presente na injecao tem
inicio desconhecido. Fontes que nao usam NoFall precisam ser identificadas em
jogo antes de serem adicionadas.

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
Config. Brandish aceita tambem as outras IDs de animacao do seu Tool (normal
e com fogo), usando o mesmo cooldown e a mesma medicao. A variante com fogo
tambem reconhece a ID 14485249284 capturada em jogo, mesmo fora do Tool. Animacoes compartilhadas entre skills nao sao atribuidas automaticamente.
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
Visuais testados com objetos simulados: cobertura/expiracao/opacidade,
visibilidade da hotbar, opacidade minima/maxima, preenchimento dentro do slot,
faixa branca sem texto de status, NoFall presente/ausente, tempos conhecidos/desconhecidos,
independencia do indicador de protecao e limpeza ao descarregar.
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

## Mana ao lado do personagem
Interface > Mana ao lado do personagem: copia o widget original de StatGui.LeftContainer.Mana
e sincroniza seu preenchimento, cores e imagens. Ajustes de posicao horizontal/vertical,
largura, altura, opacidade de 1 a 100 e valor numerico opcional; salvos pelos perfis.
A copia acompanha o personagem local na tela e desaparece sem personagem, fora da camera,
na morte ou se a barra original estiver escondida. Restart Script remove e recria a copia.

### Gate e Gelidus
A copia de mana mostra faixas de Gate, Gelidus normal e snap Gelidus, selecionadas
pela magia equipada ou pelo menu Mostrar faixas. Os limites usam a tabela de spells
do Hydroxide e os mesmos ajustes de ScholarsBoon, WiseCasting e RemTraining.
Mana dentro de uma faixa visivel: valor verde e opacidade +15 pontos, limitada a 100%.
Opacidade fora da faixa tem padrao 70%; perfis anteriores preservam o valor salvo.
Misc > Snap Gelidus Anti Backfire (ligado por padrao) bloqueia RightClick com Gelidus
equipado fora da faixa de snap, sem alterar cast normal. Durante SnapCool (tag
ou marcador no personagem), o M2 passa normalmente, seguindo a excecao do guard de Viribus. PhilosophersStone dispensa
o bloqueio, como no guard de Gate. A faixa base de snap Gelidus e 85-100%.

## Carregamento rapido
O loader compara versoes por arquivo e reutiliza o cache local: atualizacoes baixam
apenas arquivos alterados/ausentes/truncados, com ate quatro downloads simultaneos.
A instalacao anterior valida migra sem baixar novamente os arquivos iguais.
Downloads terminam antes de gravar; escrita interrompida invalida o cache para reparo.
A inicializacao nao espera pelo LeaderboardGui, que nao e requisito da interface.
Para abrir somente a copia ja instalada, sem verificar atualizacoes no GitHub:
```lua
loadstring(readfile("HYDROXIDE_LOCAL/start.lua"))()
```
Restart Script continua verificando atualizacoes. O console mostra tempo de preparo do cache.
