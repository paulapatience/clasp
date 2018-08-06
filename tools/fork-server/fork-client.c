#include <stdlib.h>
#include<stdio.h>
#include <readline/readline.h>
#include <readline/history.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#include <string.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <signal.h>

int otherpid = 42;

int signal_other_pid(int sig)
{
  if (otherpid != 0) {
    if (kill(otherpid, sig) == -1) {
      perror("kill otherpid");
      return -1;
    } else {
      otherpid = 0;
    }
  } else {
    fprintf(stderr, "otherpid was already 0\n");
  }
  return 0;
}

void onsig(int sig)
{
  signal_other_pid(sig);
  signal(sig, SIG_DFL);
  kill(getpid(), sig);
}

void onexit(void)
{
  if (otherpid != 0) {
    signal_other_pid(SIGINT);
  }
}

void socket_write_line(int sid, const char* buffer)
{
  write(sid,(void*)buffer,strlen(buffer));
  write(sid,(void*)"\n",strlen("\n"));
}

int socket_read_line(int sid, char* buffer, int buffer_size)
{
  int pos = 0;
  while (1) {
    int rread = read(sid,&buffer[pos],buffer_size-pos);
    if (buffer[pos+rread-1] == '\n') {
      buffer[pos+rread-1] = '\0';
      break;
    }
    if (rread+pos>buffer_size) perror("Read overflow");
    pos += rread;
    buffer[pos] = '\0';
  }
  return pos;
}

    
    
  
int main(int argc, const char* argv[])
{
  signal(SIGINT, onsig);
  signal(SIGQUIT, onsig);
  signal(SIGTERM, onsig);
  atexit(onexit);
  int sid;
  size_t port = strtol(argv[2],NULL,10);
  struct sockaddr_in ssock,csock;
  sid=socket(AF_INET,SOCK_STREAM,0);
  ssock.sin_family=AF_INET;
  ssock.sin_addr.s_addr=inet_addr("127.0.0.1");
  ssock.sin_port=htons(port);
//  fcntl(sid, F_SETFL, O_NONBLOCK);
  int err = connect(sid,(struct sockaddr *)&ssock,sizeof(ssock));
  if (err<0) {
    perror("connect");
  }
  const char* s = argv[1];
  printf("Sending: |%s|\n", s);
  socket_write_line(sid,s);
  char buffer[1024];
  int rread = socket_read_line(sid,buffer,1024);
  if (rread > 0 && rread < 1024) {
    printf("rread = %d  buffer = %s\n", rread, buffer);
    buffer[rread] = '\0';
    otherpid = strtol(buffer,NULL,10);
    printf("Read child pid: %d\n", otherpid);
  } else {
    perror("read response");
  }
  char bpid[1024];
  sprintf(bpid,"%d", getpid());
  socket_write_line(sid,bpid);
  printf("Sent my pid: %s\n", bpid);
  printf("Starting client loop\n");
  while(1)
  {
    char* line = readline("fork-server client> ");
    if (line) {
      printf("Read: %s\n", line);
      free(line);
    } else {
      printf("Nothing read\n");
    }
    printf("Sleep(10)\n");
    sleep(10);
//    read(sid,(void*)s1,sizeof(s1));
//    printf("\n The received string is:%s\n",s1);
  }
  close(sid);
}
